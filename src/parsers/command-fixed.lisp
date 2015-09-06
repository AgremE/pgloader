;;;
;;; LOAD FIXED COLUMNS FILE
;;;
;;; That has lots in common with CSV, so we share a fair amount of parsing
;;; rules with the CSV case.
;;;

(in-package #:pgloader.parser)

(defrule hex-number (and "0x" (+ (hexdigit-char-p character)))
  (:lambda (hex)
    (bind (((_ digits) hex))
      (parse-integer (text digits) :radix 16))))

(defrule dec-number (+ (digit-char-p character))
  (:lambda (digits)
    (parse-integer (text digits))))

(defrule number (or hex-number dec-number))

(defrule field-start-position (and (? kw-from) ignore-whitespace number)
  (:destructure (from ws pos) (declare (ignore from ws)) pos))

(defrule fixed-field-length (and (? kw-for) ignore-whitespace number)
  (:destructure (for ws len) (declare (ignore for ws)) len))

(defrule fixed-source-field (and csv-field-name
				 field-start-position fixed-field-length
				 csv-field-options)
  (:destructure (name start len opts)
    `(,name :start ,start :length ,len ,@opts)))

(defrule another-fixed-source-field (and comma fixed-source-field)
  (:lambda (source)
    (bind (((_ field) source)) field)))

(defrule fixed-source-fields (and fixed-source-field (* another-fixed-source-field))
  (:lambda (source)
    (destructuring-bind (field1 fields) source
      (list* field1 fields))))

(defrule fixed-source-field-list (and open-paren fixed-source-fields close-paren)
  (:lambda (source)
    (bind (((_ field-defs _) source)) field-defs)))

(defrule fixed-option (or option-batch-rows
                          option-batch-size
                          option-batch-concurrency
                          option-truncate
                          option-drop-indexes
                          option-disable-triggers
			  option-skip-header))

(defrule another-fixed-option (and comma fixed-option)
  (:lambda (source)
    (bind (((_ option) source)) option)))

(defrule fixed-option-list (and fixed-option (* another-fixed-option))
  (:lambda (source)
    (destructuring-bind (opt1 opts) source
      (alexandria:alist-plist `(,opt1 ,@opts)))))

(defrule fixed-options (and kw-with csv-option-list)
  (:lambda (source)
    (bind (((_ opts) source))
      (cons :fixed-options opts))))

(defrule fixed-uri (and "fixed://" filename)
  (:lambda (source)
    (bind (((_ filename) source))
      (make-instance 'fixed-connection :spec filename))))

(defrule fixed-file-source (or stdin
			       inline
                               http-uri
                               fixed-uri
			       filename-matching
			       maybe-quoted-filename)
  (:lambda (src)
    (if (typep src 'fixed-connection) src
        (destructuring-bind (type &rest specs) src
          (case type
            (:stdin    (make-instance 'fixed-connection :spec src))
            (:inline   (make-instance 'fixed-connection :spec src))
            (:filename (make-instance 'fixed-connection :spec src))
            (:regex    (make-instance 'fixed-connection :spec src))
            (:http     (make-instance 'fixed-connection :uri (first specs))))))))

(defrule get-fixed-file-source-from-environment-variable (and kw-getenv name)
  (:lambda (p-e-v)
    (bind (((_ varname) p-e-v)
           (connstring (getenv-default varname)))
      (unless connstring
          (error "Environment variable ~s is unset." varname))
        (parse 'fixed-file-source connstring))))

(defrule fixed-source (and kw-load kw-fixed kw-from
                           (or get-fixed-file-source-from-environment-variable
                               fixed-file-source))
  (:lambda (src)
    (bind (((_ _ _ source) src)) source)))

(defrule load-fixed-cols-file-optional-clauses (* (or fixed-options
                                                      gucs
                                                      before-load
                                                      after-load))
  (:lambda (clauses-list)
    (alexandria:alist-plist clauses-list)))

(defrule load-fixed-cols-file-command (and fixed-source (? file-encoding)
                                           fixed-source-field-list
                                           target
                                           (? csv-target-column-list)
                                           load-fixed-cols-file-optional-clauses)
  (:lambda (command)
    (destructuring-bind (source encoding fields target columns clauses) command
      `(,source ,encoding ,fields ,target ,columns ,@clauses))))

(defun lisp-code-for-loading-from-fixed (fixed-conn fields pg-db-conn
                                         &key
                                           (encoding :utf-8)
                                           columns
                                           gucs before after
                                           ((:fixed-options options)))
  `(lambda ()
     (let* ((state-before  (pgloader.utils:make-pgstate))
            (summary       (null *state*))
            (*state*       (or *state* (pgloader.utils:make-pgstate)))
            (state-idx    ,(when (getf options :drop-indexes)
                                 `(pgloader.utils:make-pgstate)))
            (state-after  ,(when (or after (getf options :drop-indexes))
                                 `(pgloader.utils:make-pgstate)))
            ,@(pgsql-connection-bindings pg-db-conn gucs)
            ,@(batch-control-bindings options)
            (source-db     (with-stats-collection ("fetch" :state state-before)
                               (expand (fetch-file ,fixed-conn)))))

       (progn
         ,(sql-code-block pg-db-conn 'state-before before "before load")

         (let ((truncate ,(getf options :truncate))
               (disable-triggers ,(getf options :disable-triggers))
               (drop-indexes     ,(getf options :drop-indexes))
               (source
                (make-instance 'pgloader.fixed:copy-fixed
                               :target-db ,pg-db-conn
                               :source source-db
                               :target ',(pgconn-table-name pg-db-conn)
                               :encoding ,encoding
                               :fields ',fields
                               :columns ',columns
                               :skip-lines ,(or (getf options :skip-line) 0))))

           (pgloader.sources:copy-from source
                                       :state-before state-before
                                       :state-after state-after
                                       :state-indexes state-idx
                                       :truncate truncate
                                       :drop-indexes drop-indexes
                                       :disable-triggers disable-triggers))

         ,(sql-code-block pg-db-conn 'state-after after "after load")

         ;; reporting
         (when summary
           (report-full-summary "Total import time" *state*
                                :before  state-before
                                :finally state-after
                                :parallel state-idx))))))

(defrule load-fixed-cols-file load-fixed-cols-file-command
  (:lambda (command)
    (bind (((source encoding fields pg-db-uri columns
                    &key ((:fixed-options options)) gucs before after) command))
      (cond (*dry-run*
             (lisp-code-for-csv-dry-run pg-db-uri))
            (t
             (lisp-code-for-loading-from-fixed source fields pg-db-uri
                                               :encoding encoding
                                               :columns columns
                                               :gucs gucs
                                               :before before
                                               :after after
                                               :fixed-options options))))))
