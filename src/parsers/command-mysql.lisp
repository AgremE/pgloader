;;;
;;; Parse the pgloader commands grammar
;;;

(in-package :pgloader.parser)

;;;
;;; Materialize views by copying their data over, allows for doing advanced
;;; ETL processing by having parts of the processing happen on the MySQL
;;; query side.
;;;
(defrule view-name (and (alpha-char-p character)
			(* (or (alpha-char-p character)
			       (digit-char-p character)
			       #\_)))
  (:text t))

(defrule view-sql (and kw-as dollar-quoted)
  (:destructure (as sql) (declare (ignore as)) sql))

(defrule view-definition (and view-name (? view-sql))
  (:destructure (name sql) (cons name sql)))

(defrule another-view-definition (and comma view-definition)
  (:lambda (source)
    (bind (((_ view) source)) view)))

(defrule views-list (and view-definition (* another-view-definition))
  (:lambda (vlist)
    (destructuring-bind (view1 views) vlist
      (list* view1 views))))

(defrule materialize-all-views (and kw-materialize kw-all kw-views)
  (:constant :all))

(defrule materialize-view-list (and kw-materialize kw-views views-list)
  (:destructure (mat views list) (declare (ignore mat views)) list))

(defrule materialize-views (or materialize-view-list materialize-all-views)
  (:lambda (views)
    (cons :views views)))


;;;
;;; Including only some tables or excluding some others
;;;
(defrule namestring-or-regex (or quoted-namestring quoted-regex))

(defrule another-namestring-or-regex (and comma namestring-or-regex)
  (:lambda (source)
    (bind (((_ re) source)) re)))

(defrule filter-list-matching
    (and namestring-or-regex (* another-namestring-or-regex))
  (:lambda (source)
    (destructuring-bind (filter1 filters) source
      (list* filter1 filters))))

(defrule including-matching
    (and kw-including kw-only kw-table kw-names kw-matching filter-list-matching)
  (:lambda (source)
    (bind (((_ _ _ _ _ filter-list) source))
      (cons :including filter-list))))

(defrule excluding-matching
    (and kw-excluding kw-table kw-names kw-matching filter-list-matching)
  (:lambda (source)
    (bind (((_ _ _ _ filter-list) source))
      (cons :excluding filter-list))))


;;;
;;; Per table encoding options, because MySQL is so bad at encoding...
;;;
(defrule decoding-table-as (and kw-decoding kw-table kw-names kw-matching
                                filter-list-matching
                                kw-as encoding)
  (:lambda (source)
    (bind (((_ _ _ _ filter-list _ encoding) source))
      (cons encoding filter-list))))

(defrule decoding-tables-as (+ decoding-table-as)
  (:lambda (tables)
    (cons :decoding tables)))


;;;
;;; Allow clauses to appear in any order
;;;
(defrule load-mysql-optional-clauses (* (or mysql-options
                                            gucs
                                            casts
                                            materialize-views
                                            including-matching
                                            excluding-matching
                                            decoding-tables-as
                                            before-load
                                            after-load))
  (:lambda (clauses-list)
    (alexandria:alist-plist clauses-list)))

(defrule mysql-prefix "mysql://" (:constant (list :type :mysql)))

(defrule mysql-dsn-dbname (and "/" (* (or (alpha-char-p character)
                                          (digit-char-p character)
                                          punct)))
  (:destructure (slash dbname)
		(declare (ignore slash))
		(list :dbname (text dbname))))

(defrule mysql-uri (and mysql-prefix
                        (? dsn-user-password)
                        (? dsn-hostname)
                        mysql-dsn-dbname)
  (:lambda (uri)
    (destructuring-bind (&key type
                              user
			      password
			      host
			      port
			      dbname)
        (apply #'append uri)
      ;; Default to environment variables as described in
      ;;  http://dev.mysql.com/doc/refman/5.0/en/environment-variables.html
      (declare (ignore type))
      (make-instance 'mysql-connection
                     :user (or user     (getenv-default "USER"))
                     :pass (or password (getenv-default "MYSQL_PWD"))
                     :host (or host     (getenv-default "MYSQL_HOST" "localhost"))
                     :port (or port     (parse-integer
                                         (getenv-default "MYSQL_TCP_PORT" "3306")))
                     :name dbname))))

(defrule get-mysql-uri-from-environment-variable (and kw-getenv name)
  (:lambda (p-e-v)
    (bind (((_ varname) p-e-v))
      (let ((connstring (getenv-default varname)))
        (unless connstring
          (error "Environment variable ~s is unset." varname))
        (parse 'mysql-uri connstring)))))

(defrule mysql-source (and kw-load kw-database kw-from
                           (or mysql-uri
                               get-mysql-uri-from-environment-variable))
  (:lambda (source) (bind (((_ _ _ uri) source)) uri)))

(defrule load-mysql-command (and mysql-source target
                                 load-mysql-optional-clauses)
  (:lambda (command)
    (destructuring-bind (source target clauses) command
      `(,source ,target ,@clauses))))


;;; LOAD DATABASE FROM mysql://
(defun lisp-code-for-mysql-dry-run (my-db-conn pg-db-conn)
  `(lambda ()
     (log-message :log "DRY RUN, only checking connections.")
     (check-connection ,my-db-conn)
     (check-connection ,pg-db-conn)))

(defun lisp-code-for-loading-from-mysql (my-db-conn pg-db-conn
                                         &key
                                           gucs casts views before after
                                           ((:mysql-options options))
                                           ((:including incl))
                                           ((:excluding excl))
                                           ((:decoding decoding-as)))
  `(lambda ()
     (let* ((state-before  (pgloader.utils:make-pgstate))
            (*state*       (or *state* (pgloader.utils:make-pgstate)))
            (state-idx     (pgloader.utils:make-pgstate))
            (state-after   (pgloader.utils:make-pgstate))
            (*default-cast-rules* ',*mysql-default-cast-rules*)
            (*cast-rules*         ',casts)
            ,@(pgsql-connection-bindings pg-db-conn gucs)
            ,@(batch-control-bindings options)
            ,@(identifier-case-binding options)
            (source
             (make-instance 'pgloader.mysql::copy-mysql
                            :target-db ,pg-db-conn
                            :source-db ,my-db-conn)))

       ,(sql-code-block pg-db-conn 'state-before before "before load")

       (pgloader.mysql:copy-database source
                                     :including ',incl
                                     :excluding ',excl
                                     :decoding-as ',decoding-as
                                     :materialize-views ',views
                                     :state-before state-before
                                     :state-after state-after
                                     :state-indexes state-idx
                                     ,@(remove-batch-control-option options))

       ,(sql-code-block pg-db-conn 'state-after after "after load")

       (report-full-summary "Total import time" *state*
                            :before   state-before
                            :finally  state-after
                            :parallel state-idx))))

(defrule load-mysql-database load-mysql-command
  (:lambda (source)
    (destructuring-bind (my-db-uri
                         pg-db-uri
                         &key
                         gucs casts views before after
                         mysql-options including excluding decoding)
        source
      (cond (*dry-run*
             (lisp-code-for-mysql-dry-run my-db-uri pg-db-uri))
            (t
             (lisp-code-for-loading-from-mysql my-db-uri pg-db-uri
                                               :gucs gucs
                                               :casts casts
                                               :views views
                                               :before before
                                               :after after
                                               :mysql-options mysql-options
                                               :including including
                                               :excluding excluding
                                               :decoding decoding))))))

