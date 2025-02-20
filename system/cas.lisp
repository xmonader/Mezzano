;;;; Copyright (c) 2011-2016 Henry Harrington <henry.harrington@gmail.com>
;;;; This code is licensed under the MIT license.

(in-package :sys.int)

(eval-when (:compile-toplevel :load-toplevel :execute)

;; Follows SBCL's interface, returns six values:
;; list of temporary variables
;; list of value-forms whose results those variable must be bound
;; temporary variable for the old value of place
;; temporary variable for the new value of place
;; form using the aforementioned temporaries which performs the compare-and-swap operation on place
;; form using the aforementioned temporaries with which to perform a volatile read of place
;;
;; A volatile write form might be nice as well, for unlocking spinlocks...
(defun get-cas-expansion (place &optional environment)
  (let ((expansion (macroexpand place environment)))
    (cond ((symbolp expansion)
           ;; Lexical variables would be ok to cas (captured variables, etc),
           ;; but special variables wouldn't be.
           (when (not (eql (symbol-mode expansion) :global))
             (error "CAS on a non-global symbol or variable not supported."))
           (let ((old (gensym "OLD"))
                 (new (gensym "NEW")))
             (values '()
                     '()
                     old
                     new
                     `(funcall #'(cas symbol-global-value) ,old ,new ',expansion)
                     `(symbol-global-value ',expansion))))
          (t
           ;; All other CAS forms are currently functions!
           (let ((old (gensym "OLD"))
                 (new (gensym "NEW"))
                 (vars (loop
                          for arg in (rest expansion)
                          collect (gensym))))
             (values vars
                     (copy-list (rest expansion))
                     old
                     new
                     `(funcall #'(cas ,(first expansion)) ,old ,new ,@vars)
                     `(,(first expansion) ,@vars)))))))

)

(defmacro cas (place old new &environment environment)
  (multiple-value-bind (vars vals old-sym new-sym cas-form)
      (get-cas-expansion place environment)
    `(let (,@(mapcar #'list vars vals)
           (,old-sym ,old)
           (,new-sym ,new))
       ,cas-form)))
