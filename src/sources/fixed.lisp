;;;
;;; Tools to handle fixed width files
;;;

(in-package :pgloader.fixed)

(defclass fixed-connection (md-connection) ())

(defmethod initialize-instance :after ((fixed fixed-connection) &key)
  "Assign the type slot to sqlite."
  (setf (slot-value fixed 'type) "fixed"))

(defclass copy-fixed (copy)
  ((encoding    :accessor encoding	  ; file encoding
	        :initarg :encoding)	  ;
   (skip-lines  :accessor skip-lines	  ; CSV headers
	        :initarg :skip-lines	  ;
		:initform 0))
  (:documentation "pgloader Fixed Columns Data Source"))

(defmethod initialize-instance :after ((fixed copy-fixed) &key)
  "Compute the real source definition from the given source parameter, and
   set the transforms function list as needed too."
  (let ((transforms (when (slot-boundp fixed 'transforms)
		      (slot-value fixed 'transforms)))
	(columns
	 (or (slot-value fixed 'columns)
	     (pgloader.pgsql:list-columns (slot-value fixed 'target-db)
					  (slot-value fixed 'target)))))
    (unless transforms
      (setf (slot-value fixed 'transforms) (make-list (length columns))))))

(declaim (inline parse-row))

(defun parse-row (fixed-cols-specs line)
  "Parse a single line of FIXED input file and return a row of columns."
  (loop :with len := (length line)
     :for opts :in fixed-cols-specs
     :collect (destructuring-bind (&key start length &allow-other-keys) opts
                ;; some fixed format files are ragged on the right, meaning
                ;; that we might have missing characters on each line.
                ;; take all that we have and return nil for missing data.
                (let ((end (+ start length)))
                  (when (<= start len)
                    (subseq line start (min len end)))))))

(defmethod map-rows ((fixed copy-fixed) &key process-row-fn)
  "Load data from a text file in Fixed Columns format.

   Each row is pre-processed then PROCESS-ROW-FN is called with the row as a
   list as its only parameter.

   Returns how many rows where read and processed."
  (with-connection (cnx (source fixed))
    (loop :for input := (open-next-stream cnx
                                          :direction :input
                                          :external-format (encoding fixed)
                                          :if-does-not-exist nil)
       :while input
       :do (progn ;; ignore as much as skip-lines lines in the file
             (loop repeat (skip-lines fixed) do (read-line input nil nil))

             ;; read in the text file, split it into columns, process NULL
             ;; columns the way postmodern expects them, and call
             ;; PROCESS-ROW-FN on them
             (let ((reformat-then-process
                    (reformat-then-process :fields  (fields fixed)
                                           :columns (columns fixed)
                                           :target  (target fixed)
                                           :process-row-fn process-row-fn)))
               (loop
                  :with fun := (compile nil reformat-then-process)
                  :with fixed-cols-specs := (mapcar #'cdr (fields fixed))
                  :for line := (read-line input nil nil)
                  :counting line :into read
                  :while line
                  :do (handler-case
                          (funcall fun (parse-row fixed-cols-specs line))
                        (condition (e)
                          (progn
                            (log-message :error "~a" e)
                            (pgstate-incf *state* (target fixed) :errs 1))))))))))

(defmethod copy-to-queue ((fixed copy-fixed) queue)
  "Copy data from given FIXED definition into lparallel.queue DATAQ"
  (pgloader.queue:map-push-queue fixed queue))

(defmethod copy-from ((fixed copy-fixed)
                      &key
                        state-before
                        state-after
                        state-indexes
                        truncate
                        disable-triggers
                        drop-indexes)
  "Copy data from given FIXED file definition into its PostgreSQL target table."
  (let* ((summary        (null *state*))
	 (*state*        (or *state* (pgloader.utils:make-pgstate)))
	 (lp:*kernel*    (make-kernel 2))
	 (channel        (lp:make-channel))
	 (queue          (lq:make-queue :fixed-capacity *concurrent-batches*))
         (indexes        (maybe-drop-indexes (target-db fixed)
                                             (target fixed)
                                             state-before
                                             :drop-indexes drop-indexes)))

    (with-stats-collection ((target fixed)
                            :dbname (db-name (target-db fixed))
                            :state *state*
                            :summary summary)
      (lp:task-handler-bind () ;; ((error #'lp:invoke-transfer-error))
        (log-message :notice "COPY ~a" (target fixed))
        (lp:submit-task channel #'copy-to-queue fixed queue)

        ;; and start another task to push that data from the queue to PostgreSQL
        (lp:submit-task channel
                        ;; this function update :rows stats
                        #'pgloader.pgsql:copy-from-queue
                        (target-db fixed) (target fixed) queue
                        ;; we only are interested into the column names here
                        :columns (mapcar (lambda (col)
                                           ;; always double quote column names
                                           (format nil "~s" (car col)))
                                         (columns fixed))
                        :truncate truncate
                        :disable-triggers disable-triggers)

        ;; now wait until both the tasks are over
        (loop for tasks below 2 do (lp:receive-result channel)
           finally (lp:end-kernel))))

    ;; re-create the indexes
    (create-indexes-again (target-db fixed) indexes state-after state-indexes
                          :drop-indexes drop-indexes)))

