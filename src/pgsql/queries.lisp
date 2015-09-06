;;;
;;; Tools to handle PostgreSQL queries
;;;
(in-package :pgloader.pgsql)

;;;
;;; PostgreSQL Tools connecting to a database
;;;
(defclass pgsql-connection (db-connection)
  ((use-ssl :initarg :use-ssl :accessor pgconn-use-ssl)
   (table-name :initarg :table-name :accessor pgconn-table-name))
  (:documentation "PostgreSQL connection for pgloader"))

(defmethod initialize-instance :after ((pgconn pgsql-connection) &key)
  "Assign the type slot to pgsql."
  (setf (slot-value pgconn 'type) "pgsql"))

(defun new-pgsql-connection (pgconn)
  "Prepare a new connection object with all the same properties as pgconn,
   so as to avoid stepping on it's handle"
  (make-instance 'pgsql-connection
                 :user (db-user pgconn)
                 :pass (db-pass pgconn)
                 :host (db-host pgconn)
                 :port (db-port pgconn)
                 :name (db-name pgconn)
                 :use-ssl (pgconn-use-ssl pgconn)
                 :table-name (pgconn-table-name pgconn)))

(defmethod open-connection ((pgconn pgsql-connection) &key username)
  "Open a PostgreSQL connection."
  (setf (conn-handle pgconn)
        (pomo:connect (db-name pgconn)
                      (or username (db-user pgconn))
                      (db-pass pgconn)
                      (let ((host (db-host pgconn)))
                        (if (and (consp host) (eq :unix (car host))) :unix host))
                      :port (db-port pgconn)
                      :use-ssl (or (pgconn-use-ssl pgconn) :no)))
  pgconn)

(defmethod close-connection ((pgconn pgsql-connection))
  "Close a PostgreSQL connection."
  (pomo:disconnect (conn-handle pgconn))
  (setf (conn-handle pgconn) nil)
  pgconn)

(defmethod query ((pgconn pgsql-connection) sql &key)
  (let ((pomo:*database* (conn-handle pgconn)))
    (pomo:query sql)))

(defmacro handling-pgsql-notices (&body forms)
  "The BODY is run within a PostgreSQL transaction where *pg-settings* have
   been applied. PostgreSQL warnings and errors are logged at the
   appropriate log level."
  `(handler-bind
       ((cl-postgres:database-error
	 #'(lambda (e)
	     (log-message :error "~a" e)))
	(cl-postgres:postgresql-warning
	 #'(lambda (w)
	     (log-message :warning "~a" w)
	     (muffle-warning))))
     (progn ,@forms)))

(defmacro with-pgsql-transaction ((&key pgconn database) &body forms)
  "Run FORMS within a PostgreSQL transaction to DBNAME, reusing DATABASE if
   given."
  (if database
      `(let ((pomo:*database* ,database))
	 (handling-pgsql-notices
              (pomo:with-transaction ()
                (log-message :debug "BEGIN")
                ,@forms)))
      ;; no database given, create a new database connection
      `(with-pgsql-connection (,pgconn)
         (pomo:with-transaction ()
           (log-message :debug "BEGIN")
           ,@forms))))

(defmacro with-pgsql-connection ((pgconn) &body forms)
  "Run FROMS within a PostgreSQL connection to DBNAME. To get the connection
   spec from the DBNAME, use `get-connection-spec'."
  `(let (#+unix (cl-postgres::*unix-socket-dir*  (get-unix-socket-dir ,pgconn)))
     (with-connection (conn ,pgconn)
       (let ((pomo:*database* (conn-handle conn)))
         (log-message :debug "CONNECTED TO ~s" conn)
         (set-session-gucs *pg-settings*)
         (handling-pgsql-notices
              ,@forms)))))

(defun get-unix-socket-dir (pgconn)
  "When *pgconn* host is a (cons :unix path) value, return the right value
   for cl-postgres::*unix-socket-dir*."
  (let ((host (db-host pgconn)))
    (if (and (consp host) (eq :unix (car host)))
        ;; set to *pgconn* host value
        (directory-namestring (fad:pathname-as-directory (cdr host)))
        ;; keep as is.
        cl-postgres::*unix-socket-dir*)))

(defun set-session-gucs (alist &key transaction database)
  "Set given GUCs to given values for the current session."
  (let ((pomo:*database* (or database pomo:*database*)))
    (loop
       for (name . value) in alist
       for set = (format nil "SET~:[~; LOCAL~] ~a TO '~a'" transaction name value)
       do
	 (log-message :debug set)
	 (pomo:execute set))))

(defun pgsql-connect-and-execute-with-timing (pgconn label sql state &key (count 1))
  "Run pgsql-execute-with-timing within a newly establised connection."
  (with-pgsql-connection (pgconn)
    (pomo:with-transaction ()
      (pgsql-execute-with-timing label sql state :count count))))

(defun pgsql-execute-with-timing (label sql state &key (count 1))
  "Execute given SQL and resgister its timing into STATE."
  (multiple-value-bind (res secs)
      (timing
       (handler-case (pgsql-execute sql)
         (cl-postgres:database-error (e)
           (log-message :error "~a" e)
           (pgstate-incf state label :errs 1 :rows (- count)))))
    (declare (ignore res))
    (pgstate-incf state label :read count :rows count :secs secs)))

(defun pgsql-execute (sql &key ((:client-min-messages level)))
  "Execute given SQL in current transaction"
  (when level
    (pomo:execute
     (format nil "SET LOCAL client_min_messages TO ~a;" (symbol-name level))))

  (pomo:execute sql)

  (when level (pomo:execute (format nil "RESET client_min_messages;"))))

;;;
;;; PostgreSQL Utility Queries
;;;

;; (defun list-databases (&optional (username "postgres"))
;;   "Connect to a local database and get the database list"
;;   (with-pgsql-transaction (:dbname "postgres" :username username)
;;     (loop for (dbname) in (pomo:query
;;                            "select datname
;;                               from pg_database
;;                              where datname !~ 'postgres|template'")
;;        collect dbname)))

;; (defun list-tables (&optional dbname)
;;   "Return an alist of tables names and list of columns to pay attention to."
;;   (with-pgsql-transaction (:dbname dbname)
;;     (loop for (relname colarray) in (pomo:query "
;; select relname, array_agg(case when typname in ('date', 'timestamptz')
;;                                then attnum end
;;                           order by attnum)
;;       from pg_class c
;;            join pg_namespace n on n.oid = c.relnamespace
;;            left join pg_attribute a on c.oid = a.attrelid
;;            join pg_type t on t.oid = a.atttypid
;;      where c.relkind = 'r'
;;            and attnum > 0
;;            and n.nspname = 'public'
;;   group by relname
;; ")
;;        collect (cons relname (loop
;; 				for attnum across colarray
;; 				unless (eq attnum :NULL)
;; 				collect attnum)))))

(defun list-tables-and-fkeys (&optional schema)
  "Yet another table listing query."
  (loop for (relname fkeys) in (pomo:query (format nil "
  select relname, array_to_string(array_agg(conname), ',')
    from pg_class c
         join pg_namespace n on n.oid = c.relnamespace
         left join pg_constraint co on c.oid = co.conrelid
    where contype = 'f' and nspname = ~:[current_schema()~;'~a'~]
 group by relname;" schema schema))
     collect (cons relname (sq:split-sequence #\, fkeys))))

(defun list-columns (pgconn table-name &key schema)
  "Return a list of column names for given TABLE-NAME."
  (with-pgsql-transaction (:pgconn pgconn)
    (pomo:query (format nil "
    select attname
      from pg_class c
           join pg_namespace n on n.oid = c.relnamespace
           left join pg_attribute a on c.oid = a.attrelid
           join pg_type t on t.oid = a.atttypid
     where c.oid = '~:[~*~a~;~a.~a~]'::regclass and attnum > 0
  order by attnum" schema schema table-name) :column)))

(defun list-indexes (table-name)
  "List all indexes for TABLE-NAME in SCHEMA. A PostgreSQL connection must
   be already established when calling that function."
  (loop :for (index-name table-name table-oid primary unique sql conname condef)
     :in (pomo:query (format nil "
select i.relname,
       indrelid::regclass,
       indrelid,
       indisprimary,
       indisunique,
       pg_get_indexdef(indexrelid),
       c.conname,
       pg_get_constraintdef(c.oid)
  from pg_index x
       join pg_class i ON i.oid = x.indexrelid
       left join pg_constraint c ON c.conindid = i.oid
 where indrelid = '~@[~a.~]~a'::regclass"
                             (when (typep table-name 'cons)
                               (car table-name))
                             (typecase table-name
                               (cons   (cdr table-name))
                               (string table-name))))
     :collect (make-pgsql-index :name index-name
                                :table-name table-name
                                :table-oid table-oid
                                :primary primary
                                :unique unique
                                :columns nil
                                :sql sql
                                :conname (unless (eq :null conname) conname)
                                :condef  (unless (eq :null condef)  condef))))

(defun list-reserved-keywords (pgconn)
  "Connect to PostgreSQL DBNAME and fetch reserved keywords."
  (handler-case
      (with-pgsql-connection (pgconn)
        (pomo:query "select word
                   from pg_get_keywords()
                  where catcode IN ('R', 'T')" :column))
    ;; support for Amazon Redshift
    (cl-postgres-error::syntax-error-or-access-violation (e)
      ;; 42883	undefined_function
      ;;    Database error 42883: function pg_get_keywords() does not exist
      ;;
      ;; the following list comes from a manual query against a local
      ;; PostgreSQL server (version 9.5devel), it's better to have this list
      ;; than nothing at all.
      (declare (ignore e))
      (list "all"
            "analyse"
            "analyze"
            "and"
            "any"
            "array"
            "as"
            "asc"
            "asymmetric"
            "authorization"
            "binary"
            "both"
            "case"
            "cast"
            "check"
            "collate"
            "collation"
            "column"
            "concurrently"
            "constraint"
            "create"
            "cross"
            "current_catalog"
            "current_date"
            "current_role"
            "current_schema"
            "current_time"
            "current_timestamp"
            "current_user"
            "default"
            "deferrable"
            "desc"
            "distinct"
            "do"
            "else"
            "end"
            "except"
            "false"
            "fetch"
            "for"
            "foreign"
            "freeze"
            "from"
            "full"
            "grant"
            "group"
            "having"
            "ilike"
            "in"
            "initially"
            "inner"
            "intersect"
            "into"
            "is"
            "isnull"
            "join"
            "lateral"
            "leading"
            "left"
            "like"
            "limit"
            "localtime"
            "localtimestamp"
            "natural"
            "not"
            "notnull"
            "null"
            "offset"
            "on"
            "only"
            "or"
            "order"
            "outer"
            "overlaps"
            "placing"
            "primary"
            "references"
            "returning"
            "right"
            "select"
            "session_user"
            "similar"
            "some"
            "symmetric"
            "table"
            "then"
            "to"
            "trailing"
            "true"
            "union"
            "unique"
            "user"
            "using"
            "variadic"
            "verbose"
            "when"
            "where"
            "window"
            "with"))))

(defun reset-all-sequences (pgconn &key tables)
  "Reset all sequences to the max value of the column they are attached to."
  (let ((newconn (new-pgsql-connection pgconn)))
    (with-pgsql-connection (newconn)
      (set-session-gucs *pg-settings*)
      (pomo:execute "set client_min_messages to warning;")
      (pomo:execute "listen seqs")

      (when tables
        (pomo:execute
         (format nil "create temp table reloids(oid) as values ~{('~a'::regclass)~^,~}"
                 (mapcar #'apply-identifier-case tables))))

      (handler-case
          (let ((sql (format nil "
DO $$
DECLARE
  n integer := 0;
  r record;
BEGIN
  FOR r in
       SELECT 'select '
               || trim(trailing ')'
                  from replace(pg_get_expr(d.adbin, d.adrelid),
                               'nextval', 'setval'))
               || ', (select greatest(max(' || a.attname || '), 1) from only '
               || quote_ident(nspname) || '.' || quote_ident(relname) || '));' as sql
         FROM pg_class c
              JOIN pg_namespace n on n.oid = c.relnamespace
              JOIN pg_attribute a on a.attrelid = c.oid
              JOIN pg_attrdef d on d.adrelid = a.attrelid
                                 and d.adnum = a.attnum
                                 and a.atthasdef
        WHERE relkind = 'r' and a.attnum > 0
              and pg_get_expr(d.adbin, d.adrelid) ~~ '^nextval'
              ~@[and c.oid in (select oid from reloids)~]
  LOOP
    n := n + 1;
    EXECUTE r.sql;
  END LOOP;

  PERFORM pg_notify('seqs', n::text);
END;
$$; " tables)))
            (pomo:execute sql))
        ;; now get the notification signal
        (cl-postgres:postgresql-notification (c)
          (parse-integer (cl-postgres:postgresql-notification-payload c)))))))

(defun list-table-oids (table-names)
  "Return an alist of (TABLE-NAME . TABLE-OID) for all table in the
   TABLE-NAMES list. A connection must be established already."
  (when table-names
    (loop for (name oid)
       in (pomo:query
	   (format nil
		   "select n, n::regclass::oid from (values ~{('~a')~^,~}) as t(n)"
		   table-names))
       collect (cons name oid))))
