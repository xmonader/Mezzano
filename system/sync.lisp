;;;; Copyright (c) 2019 Henry Harrington <henry.harrington@gmail.com>
;;;; This code is licensed under the MIT license.

;;;; Syncronization primitives.
;;;;
;;;; This is the high-level side, expanding on what the supervisor provides.

(defpackage :mezzano.sync
  (:use :cl)
  (:local-nicknames (:sup :mezzano.supervisor))
  (:import-from :mezzano.supervisor
                #:wait-for-objects
                #:get-object-event
                #:thread-pool-block)
  (:export #:wait-for-objects
           #:wait-for-objects-with-timeout
           #:get-object-event

           #:thread-pool-block

           #:always-false-event
           #:always-true-event

           #:semaphore
           #:make-semaphore
           #:semaphore-name
           #:semaphore-value
           #:semaphore-up
           #:semaphore-down

           #:mailbox
           #:make-mailbox
           #:mailbox-name
           #:mailbox-capacity
           #:mailbox-n-pending-messages
           #:mailbox-empty-p
           #:mailbox-send-possible-event
           #:mailbox-receive-possible-event
           #:mailbox-send
           #:mailbox-receive
           #:mailbox-peek
           #:mailbox-flush
           ))

(in-package :mezzano.sync)

(defgeneric thread-pool-block (thread-pool blocking-function &rest arguments))

(defgeneric get-object-event (object))

(defun wait-for-objects-with-timeout (timeout &rest objects)
  "As with WAIT-FOR-OBJECTS, but with a timeout.
If TIMEOUT is NIL then this is equivalent to WAIT-FOR-OBJECTS.
Otherwise it is as if a timer object with the given TIMEOUT was included with OBJECTS.
Returns NIL if the timeout expires.
Returns the number of seconds remaining as a secondary value if TIMEOUT is non-NIL."
  (cond ((null timeout)
         ;; No timeout.
         (values (apply #'wait-for-objects objects)
                 nil))
        ((not (plusp timeout))
         ;; Special case, zero or negative timeout - just poll the events.
         (values (loop
                    for object in objects
                    when (event-wait (get-object-event object) nil)
                    collect object)
                 0))
        (t
         ;; Arbitrary timeout.
         (sup:with-timer (timer :relative timeout)
           (values (remove timer (apply #'wait-for-objects (list* timer objects)))
                   (sup:timer-remaining timer))))))

(defmethod get-object-event ((object sup:event))
  object)

(defmethod print-object ((object sup:event) stream)
  (print-unreadable-object (object stream :type t :identity t)
    (let ((name (sup:event-name object)))
      (when name
        (format stream "~A " name))
      (format stream "=> ~S" (sup:event-state object)))))

(sys.int::defglobal *always-false-event* (sup:make-event :name "Always false"))
(defun always-false-event () *always-false-event*)

(sys.int::defglobal *always-true-event* (sup:make-event :name "Always true" :state t))
(defun always-true-event () *always-true-event*)

(defmethod get-object-event ((object sup:timer))
  (sup::timer-event object))

(defmethod print-object ((object sup:timer) stream)
  (print-unreadable-object (object stream :type t :identity t)
    (let ((name (sup:timer-name object))
          (deadline (sup:timer-deadline object)))
      (when name
        (format stream "~A " name))
      (cond (deadline
             (let ((remaining (- deadline (get-internal-run-time))))
               (cond ((<= remaining 0)
                      (format stream "[expired ~D seconds ago]"
                              (float (/ (- remaining) internal-time-units-per-second))))
                     (t
                      (format stream "[~D seconds remaining]"
                              (float (/ remaining internal-time-units-per-second)))))))
            (t
             (format stream "[disarmed]"))))))

(defmethod get-object-event ((object sup:simple-irq))
  (sup::simple-irq-event object))

(defmethod print-object ((object sup:simple-irq) stream)
  (print-unreadable-object (object stream :type t :identity t)
    (format stream ":Irq ~A :Pending ~A :Masked ~A"
            (sup:simple-irq-irq object)
            (sup:simple-irq-pending-p object)
            (sup:simple-irq-masked-p object))))

(defmethod get-object-event ((object sup:irq-fifo))
  (sup::irq-fifo-data-available object))

(defmethod print-object ((object sup:irq-fifo) stream)
  (print-unreadable-object (object stream :type t :identity t)
    (format stream "~A" (sup:irq-fifo-name object))))

(defmethod get-object-event ((object sup:thread))
  (sup::thread-join-event object))

;;;; Semaphore.

(defclass semaphore ()
  ((%not-zero-event :reader semaphore-not-zero-event)
   (%lock :initform (sup:make-mutex "Internal semaphore lock") :reader semaphore-lock)
   (%value :initarg :value :accessor %semaphore-value))
  (:default-initargs :value 0))

(defmethod initialize-instance :after ((instance semaphore) &key name)
  (setf (slot-value instance '%not-zero-event)
        (sup:make-event :name name
                        :state (not (zerop (%semaphore-value instance))))))

(defmethod print-object ((object semaphore) stream)
  (print-unreadable-object (object stream :type t :identity t)
    (when (semaphore-name object)
      (format stream "~A " (semaphore-name object)))
    (format stream "~A" (semaphore-value object))))

(defmethod get-object-event ((object semaphore))
  (semaphore-not-zero-event object))

;;; Public API:

(defun make-semaphore (&key name (value 0))
  (check-type value (integer 0))
  (make-instance 'semaphore :name name :value value))

(defun semaphore-name (semaphore)
  (sup:event-name (semaphore-not-zero-event semaphore)))

(defun semaphore-value (semaphore)
  "Return SEMAPHORE's current value."
  (%semaphore-value semaphore))

(defun semaphore-up (semaphore)
  "Increment SEMAPHORE."
  (sup:with-mutex ((semaphore-lock semaphore))
    (incf (%semaphore-value semaphore))
    (setf (sup:event-state (semaphore-not-zero-event semaphore)) t))
  (values))

(defun semaphore-down (semaphore &key (wait-p t))
  "Decrement SEMAPHORE.
If SEMAPHORE's current value is 0, then this will block if WAIT-P is true
until SEMAPHORE is incremented.
Returns true if SEMAPHORE was decremented, false if WAIT-P is false and the semapore's value is 0."
  (loop
     (sup:with-mutex ((semaphore-lock semaphore))
       (when (not (zerop (%semaphore-value semaphore)))
         (decf (%semaphore-value semaphore))
         (when (zerop (%semaphore-value semaphore))
           (setf (sup:event-state (semaphore-not-zero-event semaphore)) nil))
         (return t)))
     (when (not wait-p)
       (return nil))
     (sup:event-wait (semaphore-not-zero-event semaphore))))

;;;; Mailbox. A buffered communication channel.

(defclass mailbox ()
  ((%name :reader mailbox-name :initarg :name)
   (%capacity :reader mailbox-capacity :initarg :capacity :type (or null (integer 1)))
   (%not-full-event :reader mailbox-send-possible-event)
   (%not-empty-event :reader mailbox-receive-possible-event)
   (%n-pending :initform 0 :reader mailbox-n-pending-messages)
   (%head :accessor mailbox-head)
   (%tail :accessor mailbox-tail)
   (%lock :initform (sup:make-mutex "Internal mailbox lock") :reader mailbox-lock))
  (:default-initargs :name nil :capacity nil))

(defmethod print-object ((object mailbox) stream)
  (cond ((mailbox-name object)
         (print-unreadable-object (object stream :type t :identity t)
           (format stream "~A" (mailbox-name object))))
        (t
         (print-unreadable-object (object stream :type t :identity t)))))

(defmethod initialize-instance :after ((instance mailbox) &key)
  (check-type (mailbox-capacity instance) (or null (integer 1)))
  ;; Mailbox is initially empty.
  (setf (slot-value instance '%not-full-event) (sup:make-event
                                                :name `(mailbox-send-possible-event ,instance)
                                                :state t)
        (slot-value instance '%not-empty-event) (sup:make-event
                                                 :name `(mailbox-receive-possible-event ,instance)
                                                 :state nil))
  (setf (mailbox-head instance) (cons nil nil)
        (mailbox-tail instance) (mailbox-head instance)))

(defmethod get-object-event ((object mailbox))
  ;; Mailbox is ready for receiving as long as it isn't empty
  (slot-value object '%not-empty-event))

;;; Public API:

(defun make-mailbox (&key name capacity)
  "Create a new mailbox.
CAPACITY can be NIL to indicate that there should be no limit on the number of buffered items
or a positive integer to restrict the buffer to that many items.
Returns two values representing the send & receive sides of the mailbox.
Items are sent and received in FIFO order."
  (check-type capacity (or null (integer 1)))
  (make-instance 'mailbox
                 :name name
                 :capacity capacity))

(defun mailbox-send (value mailbox &key (wait-p t))
  "Push a value into the mailbox.
If the mailbox is at capacity, this will block if WAIT-P is true.
Returns true if the value was pushed, false if the mailbox is full and WAIT-P is false."
  (loop
     (sup:with-mutex ((mailbox-lock mailbox))
       (when (or (not (mailbox-capacity mailbox))
                 (< (mailbox-n-pending-messages mailbox) (mailbox-capacity mailbox)))
         ;; Space available, append to the message list.
         (let ((link (cons nil nil)))
           (setf (car (mailbox-tail mailbox)) value
                 (cdr (mailbox-tail mailbox)) link
                 (mailbox-tail mailbox) link))
         (setf (sup:event-state (mailbox-receive-possible-event mailbox)) t)
         (incf (slot-value mailbox '%n-pending))
         (when (eql (mailbox-n-pending-messages mailbox) (mailbox-capacity mailbox))
           ;; Mailbox now full.
           (setf (sup:event-state (mailbox-send-possible-event mailbox)) nil))
         (return t)))
     (when (not wait-p)
       (return nil))
     (sup:event-wait (mailbox-send-possible-event mailbox))))

(defun mailbox-receive (mailbox &key (wait-p t))
  "Pop a value from the mailbox.
If the mailbox is empty, this will block if WAIT-P is true."
  (loop
     (sup:with-mutex ((mailbox-lock mailbox))
       (when (not (zerop (mailbox-n-pending-messages mailbox)))
         ;; Messages pending.
         ;; Grab the first one.
         (let ((message (pop (mailbox-head mailbox))))
           (when (endp (cdr (mailbox-head mailbox)))
             ;; This was the last message.
             (setf (sup:event-state (mailbox-receive-possible-event mailbox)) nil))
           (decf (slot-value mailbox '%n-pending))
           (setf (sup:event-state (mailbox-send-possible-event mailbox)) t)
           (return (values message t))))
       (when (not wait-p)
         (return (values nil nil))))
     (sup:event-wait (mailbox-receive-possible-event mailbox))))

(defun mailbox-peek (mailbox &key (wait-p t))
  "Peek at the next pending message in the mailbox, if any.
Like MAILBOX-RECEIVE, but leaves the message in the mailbox."
  (loop
     (sup:with-mutex ((mailbox-lock mailbox))
       (when (not (zerop (mailbox-n-pending-messages mailbox)))
         ;; Messages pending.
         ;; Grab the first one.
         (return (values (first (mailbox-head mailbox))
                         t)))
       (when (not wait-p)
         (return (values nil nil))))
     (sup:event-wait (mailbox-receive-possible-event mailbox))))

(defun mailbox-flush (mailbox)
  "Empty MAILBOX, returning a list of all pending messages."
  (sup:with-mutex ((mailbox-lock mailbox))
    (let ((messages (butlast (mailbox-head mailbox))))
      (setf (mailbox-head mailbox) (cons nil nil)
            (mailbox-tail mailbox) (mailbox-head mailbox))
      (setf (slot-value mailbox '%n-pending) 0)
      (setf (sup:event-state (mailbox-send-possible-event mailbox)) t
            (sup:event-state (mailbox-receive-possible-event mailbox)) nil)
      messages)))

(defun mailbox-empty-p (mailbox)
  "Returns true if there are no messages waiting."
  (zerop (mailbox-n-pending-messages mailbox)))

;;;; Compatibility wrappers.

(deftype sup:latch ()
  'event)

(defun sup:latch-p (object)
  (typep object 'sup:latch))

(defun sup:make-latch (&optional name)
  (make-event :name name))

(defun sup:latch-reset (latch)
  (setf (event-state latch) nil))

(defun sup:latch-wait (latch)
  (event-wait latch)
  (values))

(defun sup:latch-trigger (latch)
  (setf (event-state latch) t))

(deftype sup:fifo ()
  'mailbox)

(defun sup:fifo-p (object)
  (typep object 'sup:fifo))

(defun sup:make-fifo (size &key (element-type 't))
  (declare (ignore element-type))
  (make-mailbox :capacity size))

(defun sup:fifo-push (value fifo &optional (wait-p t))
  (mailbox-send value fifo :wait-p wait-p))

(defun sup:fifo-pop (fifo &optional (wait-p t))
  (mailbox-receive fifo :wait-p wait-p))

(defun sup:fifo-reset (fifo)
  (mailbox-flush fifo))

(defun sup:fifo-size (fifo)
  (mailbox-capacity fifo))

(defun sup:fifo-element-type (fifo)
  't)
