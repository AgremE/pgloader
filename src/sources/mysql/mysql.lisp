;;;
;;; Tools to handle MySQL data fetching
;;;

(in-package :pgloader.mysql)

(defclass copy-mysql (copy)
  ((encoding :accessor encoding         ; allows forcing encoding
             :initarg :encoding
             :initform nil))
  (:documentation "pgloader MySQL Data Source"))

(defun cast-mysql-column-definition-to-pgsql (mysql-column)
  "Return the PostgreSQL column definition from the MySQL one."
  (with-slots (table-name name dtype ctype default nullable extra)
      mysql-column
    (cast table-name name dtype ctype default nullable extra)))

(defmethod initialize-instance :after ((source copy-mysql) &key)
  "Add a default value for transforms in case it's not been provided."
  (let ((transforms (and (slot-boundp source 'transforms)
                         (slot-value  source 'transforms))))
    (when (and (slot-boundp source 'fields) (slot-value source 'fields))
      (loop :for field :in (slot-value source 'fields)
         :for (column fn) := (multiple-value-bind (column fn)
                                 (cast-mysql-column-definition-to-pgsql field)
                               (list column fn))
         :collect column :into columns
         :collect fn :into fns
         :finally (progn (setf (slot-value source 'columns) columns)
                         (unless transforms
                           (setf (slot-value source 'transforms) fns)))))))


;;;
;;; Implement the specific methods
;;;
(defmethod map-rows ((mysql copy-mysql) &key process-row-fn)
  "Extract MySQL data and call PROCESS-ROW-FN function with a single
   argument (a list of column values) for each row."
  (let ((table-name             (source mysql))
        (qmynd:*mysql-encoding*
         (when (encoding mysql)
           #+sbcl (encoding mysql)
           #+ccl  (ccl:external-format-character-encoding (encoding mysql)))))

    (with-connection (*connection* (source-db mysql))
      (when qmynd:*mysql-encoding*
        (log-message :notice "Force encoding to ~a for ~a"
                     qmynd:*mysql-encoding* table-name))
      (let* ((cols (get-column-list (db-name (source-db mysql)) table-name))
             (sql  (format nil "SELECT ~{~a~^, ~} FROM `~a`;" cols table-name))
             (row-fn
              (lambda (row)
                (pgstate-incf *state* (target mysql) :read 1)
                (funcall process-row-fn row))))
        (handler-bind
            ;; avoid trying to fetch the character at end-of-input position...
            ((babel-encodings:end-of-input-in-character
              #'(lambda (c)
                  (pgstate-incf *state* (target mysql) :errs 1)
                  (log-message :error "~a" c)
                  (invoke-restart 'qmynd-impl::use-nil)))
             (babel-encodings:character-decoding-error
              #'(lambda (c)
                  (pgstate-incf *state* (target mysql) :errs 1)
                  (let ((encoding (babel-encodings:character-coding-error-encoding c))
                        (position (babel-encodings:character-coding-error-position c))
                        (character
                         (aref (babel-encodings:character-coding-error-buffer c)
                               (babel-encodings:character-coding-error-position c))))
                    (log-message :error
                                 "~a: Illegal ~a character starting at position ~a: ~a."
                                 table-name encoding position character))
                  (invoke-restart 'qmynd-impl::use-nil))))
          (mysql-query sql :row-fn row-fn :result-type 'vector))))))

;;;
;;; Use map-rows and pgsql-text-copy-format to fill in a CSV file on disk
;;; with MySQL data in there.
;;;
(defmethod copy-to ((mysql copy-mysql) filename)
  "Extract data from MySQL in PostgreSQL COPY TEXT format"
  (with-open-file (text-file filename
			     :direction :output
			     :if-exists :supersede
			     :external-format :utf-8)
    (map-rows mysql
	      :process-row-fn
	      (lambda (row)
		(format-vector-row text-file row (transforms mysql))))))

;;;
;;; Export MySQL data to our lparallel data queue. All the work is done in
;;; other basic layers, simple enough function.
;;;
(defmethod copy-to-queue ((mysql copy-mysql) queue)
  "Copy data from MySQL table DBNAME.TABLE-NAME into queue DATAQ"
  (map-push-queue mysql queue))


;;;
;;; Direct "stream" in between mysql fetching of results and PostgreSQL COPY
;;; protocol
;;;
(defmethod copy-from ((mysql copy-mysql)
                      &key (kernel nil k-s-p) truncate disable-triggers)
  "Connect in parallel to MySQL and PostgreSQL and stream the data."
  (let* ((summary        (null *state*))
	 (*state*        (or *state* (pgloader.utils:make-pgstate)))
	 (lp:*kernel*    (or kernel (make-kernel 2)))
	 (channel        (lp:make-channel))
	 (queue          (lq:make-queue :fixed-capacity *concurrent-batches*))
	 (table-name     (target mysql)))

    ;; we account stats against the target table-name, because that's all we
    ;; know on the PostgreSQL thread
    (with-stats-collection (table-name
                            :dbname (db-name (target-db mysql))
                            :state *state*
                            :summary summary)
      (lp:task-handler-bind ((error #'lp:invoke-transfer-error))
        (log-message :notice "COPY ~a" table-name)
        ;; read data from MySQL
        (lp:submit-task channel #'copy-to-queue mysql queue)

        ;; and start another task to push that data from the queue to PostgreSQL
        (lp:submit-task channel #'pgloader.pgsql:copy-from-queue
                        (target-db mysql) (target mysql) queue
                        :columns (mapcar #'apply-identifier-case
                                         (mapcar #'mysql-column-name
                                                 (fields mysql)))
                        :truncate truncate
                        :disable-triggers disable-triggers)

        ;; now wait until both the tasks are over
        (loop for tasks below 2 do (lp:receive-result channel)
           finally
             (log-message :info "COPY ~a done." table-name)
             (unless k-s-p (lp:end-kernel)))))

    ;; return the copy-mysql object we just did the COPY for
    mysql))


;;;
;;; Prepare the PostgreSQL database before streaming the data into it.
;;;
(defun prepare-pgsql-database (pgconn
                               all-columns all-indexes all-fkeys
                               materialize-views view-columns
                               &key
                                 state
                                 foreign-keys
                                 include-drop)
  "Prepare the target PostgreSQL database: create tables casting datatypes
   from the MySQL definitions, prepare index definitions and create target
   tables for materialized views.

   That function mutates index definitions in ALL-INDEXES."
  (log-message :notice "~:[~;DROP then ~]CREATE TABLES" include-drop)
  (log-message :debug  (if include-drop
                           "drop then create ~d tables with ~d indexes."
                           "create ~d tables with ~d indexes.")
               (length all-columns)
               (loop for (name . idxs) in all-indexes sum (length idxs)))

  (with-stats-collection ("create, drop" :use-result-as-rows t :state state)
    (with-pgsql-transaction (:pgconn pgconn)
      ;; we need to first drop the Foreign Key Constraints, so that we
      ;; can DROP TABLE when asked
      (when (and foreign-keys include-drop)
        (drop-pgsql-fkeys all-fkeys))

      ;; now drop then create tables and types, etc
      (prog1
          (create-tables all-columns :include-drop include-drop)

        ;; MySQL allows the same index name being used against several
        ;; tables, so we add the PostgreSQL table OID in the index name,
        ;; to differenciate. Set the table oids now.
        (set-table-oids all-indexes)

        ;; We might have to MATERIALIZE VIEWS
        (when materialize-views
          (create-tables view-columns :include-drop include-drop))))))

(defun complete-pgsql-database (pgconn all-columns all-fkeys pkeys
                                table-comments column-comments
                                &key
                                  state
                                  data-only
                                  foreign-keys
                                  reset-sequences)
  "After loading the data into PostgreSQL, we can now reset the sequences
     and declare foreign keys."
  ;;
  ;; Now Reset Sequences, the good time to do that is once the whole data
  ;; has been imported and once we have the indexes in place, as max() is
  ;; able to benefit from the indexes. In particular avoid doing that step
  ;; while CREATE INDEX statements are in flight (avoid locking).
  ;;
  (when reset-sequences
    (reset-sequences (mapcar #'car all-columns) :pgconn pgconn :state state))

  (with-pgsql-connection (pgconn)
    ;;
    ;; Turn UNIQUE indexes into PRIMARY KEYS now
    ;;
    (pgstate-add-table state (db-name pgconn) "Primary Keys")
    (loop :for sql :in pkeys
       :when sql
       :do (progn
             (log-message :notice "~a" sql)
             (pgsql-execute-with-timing "Primary Keys" sql state)))

    ;;
    ;; Foreign Key Constraints
    ;;
    ;; We need to have finished loading both the reference and the refering
    ;; tables to be able to build the foreign keys, so wait until all tables
    ;; and indexes are imported before doing that.
    ;;
    (when (and foreign-keys (not data-only))
      (pgstate-add-table state (db-name pgconn) "Foreign Keys")
      (loop :for (table-name . fkeys) :in all-fkeys
         :do (loop :for fkey :in fkeys
                :for sql := (format-pgsql-create-fkey fkey)
                :do (progn
                      (log-message :notice "~a;" sql)
                      (pgsql-execute-with-timing "Foreign Keys" sql state)))))

    ;;
    ;; And now, comments on tables and columns.
    ;;
    (log-message :notice "Comments")
    (pgstate-add-table state (db-name pgconn) "Comments")
    (let* ((quote
            ;; just something improbably found in a table comment, to use as
            ;; dollar quoting, and generated at random at that.
            ;;
            ;; because somehow it appears impossible here to benefit from
            ;; the usual SQL injection protection offered by the Extended
            ;; Query Protocol from PostgreSQL.
            (concatenate 'string
                         (map 'string #'code-char
                              (loop :repeat 5
                                 :collect (+ (random 26) (char-code #\A))))
                         "_"
                         (map 'string #'code-char
                              (loop :repeat 5
                                 :collect (+ (random 26) (char-code #\A)))))))
      (loop :for (table-name comment) :in table-comments
         :for sql := (format nil "comment on table ~a is $~a$~a$~a$"
                             (apply-identifier-case table-name)
                             quote comment quote)
         :do (progn
               (log-message :log "~a" sql)
               (pgsql-execute-with-timing "Comments" sql state)))

      (loop :for (table-name column-name comment) :in column-comments
         :for sql := (format nil "comment on column ~a.~a is $~a$~a$~a$"
                             (apply-identifier-case table-name)
                             (apply-identifier-case column-name)
                             quote comment quote)
         :do (progn
               (log-message :notice "~a;" sql)
               (pgsql-execute-with-timing "Comments" sql state))))))

(defun fetch-mysql-metadata (mysql
                             &key
                               state
                               materialize-views
                               only-tables
                               including
                               excluding)
  "MySQL introspection to prepare the migration."
  (let ((view-names    (unless (eq :all materialize-views)
                         (mapcar #'car materialize-views)))
        view-columns all-columns all-fkeys all-indexes
        table-comments column-comments)
   (with-stats-collection ("fetch meta data"
                           :use-result-as-rows t
                           :use-result-as-read t
                           :state state)
     (with-connection (*connection* (source-db mysql))
       ;; If asked to MATERIALIZE VIEWS, now is the time to create them in
       ;; MySQL, when given definitions rather than existing view names.
       (when (and materialize-views (not (eq :all materialize-views)))
         (create-my-views materialize-views))

       (setf all-columns   (list-all-columns :only-tables only-tables
                                             :including including
                                             :excluding excluding)

             table-comments (list-table-comments :only-tables only-tables
                                                 :including including
                                                 :excluding excluding)

             column-comments (list-columns-comments :only-tables only-tables
                                                    :including including
                                                    :excluding excluding)

             all-fkeys     (list-all-fkeys :only-tables only-tables
                                           :including including
                                           :excluding excluding)

             all-indexes   (list-all-indexes :only-tables only-tables
                                             :including including
                                             :excluding excluding)

             view-columns  (cond (view-names
                                  (list-all-columns :only-tables view-names
                                                    :table-type :view))

                                 ((eq :all materialize-views)
                                  (list-all-columns :table-type :view))))

       ;; return how many objects we're going to deal with in total
       ;; for stats collection
       (+ (length all-columns) (length all-fkeys)
          (length all-indexes) (length view-columns))))

   (log-message :notice
                "MySQL metadata fetched: found ~d tables with ~d indexes total."
                (length all-columns) (length all-indexes))

   ;; now return a plist to the caller
   (list :all-columns all-columns
         :table-comments table-comments
         :column-comments column-comments
         :all-fkeys all-fkeys
         :all-indexes all-indexes
         :view-columns view-columns)))

(defun apply-decoding-as-filters (table-name filters)
  "Return a generialized boolean which is non-nil only if TABLE-NAME matches
   one of the FILTERS."
  (flet ((apply-filter (filter)
           ;; we close over table-name here.
           (typecase filter
             (string (string-equal filter table-name))
             (list   (destructuring-bind (type val) filter
                       (ecase type
                         (:regex (cl-ppcre:scan val table-name))))))))
    (some #'apply-filter filters)))

;;;
;;; Work on all tables for given database
;;;
(defmethod copy-database ((mysql copy-mysql)
			  &key
			    state-before
			    state-after
			    state-indexes
			    (truncate         nil)
			    (disable-triggers nil)
			    (data-only        nil)
			    (schema-only      nil)
			    (create-tables    t)
			    (include-drop     t)
			    (create-indexes   t)
                            (index-names      :uniquify)
			    (reset-sequences  t)
			    (foreign-keys     t)
			    only-tables
			    including
			    excluding
                            decoding-as
			    materialize-views)
  "Export MySQL data and Import it into PostgreSQL"
  (let* ((summary       (null *state*))
	 (*state*       (or *state*       (make-pgstate)))
	 (idx-state     (or state-indexes (make-pgstate)))
	 (state-before  (or state-before  (make-pgstate)))
	 (state-after   (or state-after   (make-pgstate)))
         (copy-kernel   (make-kernel 2))
         idx-kernel idx-channel)

    (destructuring-bind (&key view-columns all-columns
                              table-comments column-comments
                              all-fkeys all-indexes pkeys)
        ;; to prepare the run, we need to fetch MySQL meta-data
        (fetch-mysql-metadata mysql
                              :state state-before
                              :materialize-views materialize-views
                              :only-tables only-tables
                              :including including
                              :excluding excluding)

      ;; prepare our lparallel kernels, dimensioning them to the known sizes
      (let ((max-indexes
             (loop for (table . indexes) in all-indexes
                maximizing (length indexes))))

        (setf idx-kernel    (when (and max-indexes (< 0 max-indexes))
                              (make-kernel max-indexes)))

        (setf idx-channel   (when idx-kernel
                              (let ((lp:*kernel* idx-kernel))
                                (lp:make-channel)))))

      ;; if asked, first drop/create the tables on the PostgreSQL side
      (handler-case
          (cond ((and (or create-tables schema-only) (not data-only))
                 (prepare-pgsql-database (target-db mysql)
                                         all-columns
                                         all-indexes
                                         all-fkeys
                                         materialize-views
                                         view-columns
                                         :state state-before
                                         :foreign-keys foreign-keys
                                         :include-drop include-drop))
                (t
                 (when truncate
                   (truncate-tables (target-db mysql) (mapcar #'car all-columns)))))
        ;;
        ;; In case some error happens in the preparatory transaction, we
        ;; need to stop now and refrain from trying to load the data into
        ;; an incomplete schema.
        ;;
        (cl-postgres:database-error (e)
          (declare (ignore e))		; a log has already been printed
          (log-message :fatal "Failed to create the schema, see above.")

          ;; we did already create our Views in the MySQL database, so clean
          ;; that up now.
          (when materialize-views
            (with-connection (*connection* (source-db mysql))
              (drop-my-views materialize-views)))

          (return-from copy-database)))

      (loop
         for (table-name . columns) in (append all-columns view-columns)

         unless columns
         do (log-message :error "Table ~s not found, skipping." table-name)

         when columns
         do
           (let* ((encoding
                   ;; force the data encoding when asked to
                   (when decoding-as
                     (loop :for (encoding . filters) :in decoding-as
                        :when (apply-decoding-as-filters table-name filters)
                        :return encoding)))

                  (table-source
                   (make-instance 'copy-mysql
                                  :source-db  (source-db mysql)
                                  :target-db  (target-db mysql)
                                  :source     table-name
                                  :target     (apply-identifier-case table-name)
                                  :fields     columns
                                  :encoding   encoding)))

             (log-message :debug "TARGET: ~a" (target table-source))

             ;; first COPY the data from MySQL to PostgreSQL, using copy-kernel
             (unless schema-only
               (copy-from table-source
                          :kernel copy-kernel
                          :disable-triggers disable-triggers))

             ;; Create the indexes for that table in parallel with the next
             ;; COPY, and all at once in concurrent threads to benefit from
             ;; PostgreSQL synchronous scan ability
             ;;
             ;; We just push new index build as they come along, if one
             ;; index build requires much more time than the others our
             ;; index build might get unsync: indexes for different tables
             ;; will get built in parallel --- not a big problem.
             (when (and create-indexes (not data-only))
               (let* ((indexes
                       (cdr (assoc table-name all-indexes :test #'string=)))
                      (*preserve-index-names* (eq :preserve index-names)))
                 (alexandria:appendf
                  pkeys
                  (create-indexes-in-kernel (target-db mysql)
                                            indexes idx-kernel idx-channel
                                            :state idx-state))))))

      ;; now end the kernels
      (let ((lp:*kernel* copy-kernel))  (lp:end-kernel))
      (let ((lp:*kernel* idx-kernel))
        ;; wait until the indexes are done being built...
        ;; don't forget accounting for that waiting time.
        (when (and create-indexes (not data-only))
          (with-stats-collection ("Index Build Completion" :state *state*)
            (loop for idx in all-indexes do (lp:receive-result idx-channel))))
        (lp:end-kernel))

      ;;
      ;; If we created some views for this run, now is the time to DROP'em
      ;;
      (when materialize-views
        (with-connection (*connection* (source-db mysql))
          (drop-my-views materialize-views)))

      ;;
      ;; Complete the PostgreSQL database before handing over.
      ;;
      (complete-pgsql-database (new-pgsql-connection (target-db mysql))
                               all-columns all-fkeys pkeys
                               table-comments column-comments
                               :state state-after
                               :data-only data-only
                               :foreign-keys foreign-keys
                               :reset-sequences reset-sequences)

      ;; and report the total time spent on the operation
      (when summary
        (report-full-summary "Total streaming time" *state*
                             :before   state-before
                             :finally  state-after
                             :parallel idx-state)))))
