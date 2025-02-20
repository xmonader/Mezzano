;;;; Copyright (c) 2011-2016 Henry Harrington <henry.harrington@gmail.com>
;;;; This code is licensed under the MIT license.

(in-package :mezzano.network.tcp)

(defconstant +tcp4-header-source-port+ 0)
(defconstant +tcp4-header-destination-port+ 2)
(defconstant +tcp4-header-sequence-number+ 4)
(defconstant +tcp4-header-acknowledgment-number+ 8)
(defconstant +tcp4-header-flags-and-data-offset+ 12)
(defconstant +tcp4-header-window-size+ 14)
(defconstant +tcp4-header-checksum+ 16)
(defconstant +tcp4-header-urgent-pointer+ 18)

(defconstant +tcp4-flag-fin+ #b00000001)
(defconstant +tcp4-flag-syn+ #b00000010)
(defconstant +tcp4-flag-rst+ #b00000100)
(defconstant +tcp4-flag-psh+ #b00001000)
(defconstant +tcp4-flag-ack+ #b00010000)
(defconstant +tcp4-flag-urg+ #b00100000)
(defconstant +tcp4-flag-ece+ #b01000000)
(defconstant +tcp4-flag-cwr+ #b10000000)

(defvar *tcp-connections* nil)
(defvar *tcp-connection-lock* (mezzano.supervisor:make-mutex "TCP connection list"))
(defvar *tcp-listeners* nil)
(defvar *tcp-listener-lock* (mezzano.supervisor:make-mutex "TCP connection list"))
(defvar *allocated-tcp-ports* nil)

(defvar *server-alist* '())

(defclass tcp-listener ()
  ((local-port :accessor tcp-listener-local-port :initarg :local-port)
   (local-ip :accessor tcp-listener-local-ip :initarg :local-ip)
   (connection :accessor tcp-listener-connection :initarg :connection)
   (lock :reader tcp-listener-lock :initarg :lock)
   (event :reader tcp-listener-event
          :reader mezzano.supervisor:get-object-event
          :initarg :event))
  (:default-initargs
   :lock (mezzano.supervisor:make-mutex "TCP listener lock")
   :event (mezzano.supervisor:make-event :name "TCP listener event")))

(defun close-tcp-listener (listener)
  (mezzano.supervisor:with-mutex (*tcp-listener-lock*)
    (setf *tcp-listeners* (remove listener *tcp-listeners*))))

(defun wait-for-connections (listener &key timeout)
  (mezzano.supervisor:event-wait-for ((tcp-listener-event listener) :timeout timeout)
    (mezzano.supervisor:with-mutex ((tcp-listener-lock listener))
      (prog1
          (tcp-listener-connection listener)
        (setf (tcp-listener-connection listener) '())
        ;; No more pending connections.
        (setf (mezzano.supervisor:event-state (tcp-listener-event listener)) nil)))))

(defclass tcp-connection ()
  ((%state :accessor tcp-connection-%state :initarg :%state)
   (local-port :accessor tcp-connection-local-port :initarg :local-port)
   (local-ip :accessor tcp-connection-local-ip :initarg :local-ip)
   (remote-port :accessor tcp-connection-remote-port :initarg :remote-port)
   (remote-ip :accessor tcp-connection-remote-ip :initarg :remote-ip)
   (s-next :accessor tcp-connection-s-next :initarg :s-next)
   (r-next :accessor tcp-connection-r-next :initarg :r-next)
   (window-size :accessor tcp-connection-window-size :initarg :window-size)
   (max-seg-size :accessor tcp-connection-max-seg-size :initarg :max-seg-size)
   (rx-data :accessor tcp-connection-rx-data :initarg :rx-data)
   (rx-data-unordered :accessor tcp-connection-rx-data-unordered :initarg :rx-data-unordered)
   (lock :accessor tcp-connection-lock :initarg :lock)
   (cvar :accessor tcp-connection-cvar :initarg :cvar))
  (:default-initargs
   :max-seg-size 1000
   :rx-data '()
   :rx-data-unordered (make-hash-table)
   :lock (mezzano.supervisor:make-mutex "TCP connection lock")
   :cvar (mezzano.supervisor:make-condition-variable "TCP connection cvar")))

(declaim (inline tcp-connection-state (setf tcp-connection-state)))

(defun tcp-connection-state (connection)
  (tcp-connection-%state connection))

(defun (setf tcp-connection-state) (value connection)
  (setf (tcp-connection-%state connection) value))

(defmacro with-tcp-connection-locked (connection &body body)
  `(mezzano.supervisor:with-mutex ((tcp-connection-lock ,connection))
     ,@body))

(defun get-tcp-listener (local-ip local-port)
  (mezzano.supervisor:with-mutex (*tcp-listener-lock*)
    (dolist (listener *tcp-listeners*)
      (when (and (or (mezzano.network.ip:address-equal
                      (tcp-listener-local-ip listener) local-ip)
                     (mezzano.network.ip:address-equal
                      (mezzano.network.ip:make-ipv4-address "0.0.0.0")
                      (tcp-listener-local-ip listener)))
                 (eql (tcp-listener-local-port listener) local-port))
        (return listener)))))

(defun get-tcp-connection (remote-ip remote-port local-ip local-port)
  (mezzano.supervisor:with-mutex (*tcp-connection-lock*)
    (dolist (connection *tcp-connections*)
      (when (and (mezzano.network.ip:address-equal
                  (tcp-connection-remote-ip connection)
                  remote-ip)
                 (eql (tcp-connection-remote-port connection) remote-port)
                 (mezzano.network.ip:address-equal
                  (tcp-connection-local-ip connection)
                  local-ip)
                 (eql (tcp-connection-local-port connection) local-port))
        (return connection)))))

(defun %tcp4-receive (packet local-ip remote-ip start end)
  (let* ((remote-port (ub16ref/be packet (+ start +tcp4-header-source-port+)))
         (local-port (ub16ref/be packet (+ start +tcp4-header-destination-port+)))
         (flags (ldb (byte 12 0)
                     (ub16ref/be packet (+ start +tcp4-header-flags-and-data-offset+))))
         (connection (get-tcp-connection remote-ip remote-port local-ip local-port))
         (listener (get-tcp-listener local-ip local-port)))
    (cond (connection
           (tcp4-receive connection packet start end))
          ((and listener (eql flags +tcp4-flag-syn+))
           (let ((connection (make-instance 'tcp-connection
                                            :%state :listen
                                            :local-port local-port
                                            :local-ip local-ip
                                            :remote-port remote-port
                                            :remote-ip remote-ip
                                            :s-next 0
                                            :r-next (ub32ref/be packet (+ start +tcp4-header-sequence-number+))
                                            :window-size 8192)))
             (mezzano.supervisor:with-mutex ((tcp-listener-lock listener))
               ;; Push on the end of the list.
               (setf (tcp-listener-connection listener) (append (tcp-listener-connection listener)
                                                                (list connection)))
               (setf (mezzano.supervisor:event-state (tcp-listener-event listener)) t))
             (mezzano.supervisor:with-mutex (*tcp-connection-lock*)
               (push connection *tcp-connections*))))
          ((eql flags +tcp4-flag-syn+)
           (tcp4-establish-connection local-ip local-port remote-ip remote-port packet start end)))))

(defun tcp4-accept-connection (connection)
  (let* ((seq (random #x100000000))
         (ack (logand #xFFFFFFFF (1+ (tcp-connection-r-next connection)))))
    (setf (tcp-connection-state connection) :syn-received
          (tcp-connection-s-next connection) (logand #xFFFFFFFF (1+ seq))
          (tcp-connection-r-next connection) ack)
    (tcp4-send-packet connection seq ack nil :ack-p t :syn-p t)
    (make-instance 'tcp-stream :connection connection)))

(defun tcp4-decline-connection (connection)
  (detach-tcp-connection connection))

(defun tcp4-establish-connection (local-ip local-port remote-ip remote-port packet start end)
  (let* ((seq (ub32ref/be packet (+ start +tcp4-header-sequence-number+)))
         (blah (random #x100000000))
         (connection (make-instance 'tcp-connection
                                    :%state :syn-received
                                    :local-port local-port
                                    :local-ip local-ip
                                    :remote-port remote-port
                                    :remote-ip remote-ip
                                    :s-next (logand #xFFFFFFFF (1+ blah))
                                    :r-next (logand #xFFFFFFFF (1+ seq))
                                    :window-size 8192)))
    (let ((server (assoc local-port *server-alist*)))
      (cond (server
             (mezzano.supervisor:with-mutex (*tcp-connection-lock*)
               (push connection *tcp-connections*))
             (tcp4-send-packet connection blah (logand #xFFFFFFFF (1+ seq)) nil
                               :ack-p t :syn-p t)
             (funcall (second server) connection))))))

(defun detach-tcp-connection (connection)
  (mezzano.supervisor:with-mutex (*tcp-connection-lock*)
    (setf *tcp-connections* (remove connection *tcp-connections*)))
  (setf *allocated-tcp-ports* (remove (tcp-connection-local-port connection) *allocated-tcp-ports*)))

(defun tcp4-receive-data (connection data-length end header-length packet seq start state)
  (cond ((= seq (tcp-connection-r-next connection))
         ;; Send data to the user layer
         (if (tcp-connection-rx-data connection)
             (setf (cdr (last (tcp-connection-rx-data connection)))
                   (list (list packet (+ start header-length) end)))
             (setf (tcp-connection-rx-data connection)
                   (list (list packet (+ start header-length) end))))
         (setf (tcp-connection-r-next connection)
               (logand (+ (tcp-connection-r-next connection) data-length)
                       #xFFFFFFFF))
         ;; Check if the next packet is in tcp-connection-rx-data-unordered
         (loop :for packet := (gethash (tcp-connection-r-next connection)
                                       (tcp-connection-rx-data-unordered connection))
               :always packet
               :do (remhash (tcp-connection-r-next connection)
                            (tcp-connection-rx-data-unordered connection))
               :do (setf (cdr (last (tcp-connection-rx-data connection)))
                         (list (list packet (+ start header-length) end)))
               :do (setf (tcp-connection-r-next connection)
                         (logand (+ (tcp-connection-r-next connection) data-length)
                                 #xFFFFFFFF))))
        ;; Add future packet to tcp-connection-rx-data-unordered
        ((> seq (tcp-connection-r-next connection))
         (unless (gethash seq (tcp-connection-rx-data-unordered connection))
           (setf (gethash seq (tcp-connection-rx-data-unordered connection))
                 (list (list packet (+ start header-length) end))))))
  (cond ((<= seq (tcp-connection-r-next connection))
         (tcp4-send-packet connection
                           (tcp-connection-s-next connection)
                           (tcp-connection-r-next connection)
                           nil
                           :ack-p t))))

(defun tcp4-receive (connection packet &optional (start 0) end)
  (unless end (setf end (length packet)))
  (with-tcp-connection-locked connection
    (let* ((seq (ub32ref/be packet (+ start +tcp4-header-sequence-number+)))
           (ack (ub32ref/be packet (+ start +tcp4-header-acknowledgment-number+)))
           (flags-and-data-offset (ub16ref/be packet (+ start +tcp4-header-flags-and-data-offset+)))
           (flags (ldb (byte 12 0) flags-and-data-offset))
           (header-length (* (ldb (byte 4 12) flags-and-data-offset) 4))
           (data-length (- end (+ start header-length))))
      (when (logtest flags +tcp4-flag-rst+)
        ;; Remote have sended RST , aborting connection
        (setf (tcp-connection-state connection) :connection-aborted)
        (detach-tcp-connection connection))
      (case (tcp-connection-state connection)
        (:listen
         ;; Remote has start new connection.
         ;; Not much to do here, just waiting for the application to accept or decline new connection.
         )
        (:syn-sent
         ;; Active open
         (cond ((and (logtest flags +tcp4-flag-ack+)
                     (logtest flags +tcp4-flag-syn+)
                     (eql ack (tcp-connection-s-next connection)))
                ;; Remote have sended SYN+ACK and waiting for ACK
                (setf (tcp-connection-state connection) :established
                      (tcp-connection-r-next connection) (logand (1+ seq) #xFFFFFFFF))
                (tcp4-send-packet connection ack (tcp-connection-r-next connection) nil))
               ((logtest flags +tcp4-flag-syn+)
                ;; Simultaneous open
                (setf (tcp-connection-state connection) :syn-received
                      (tcp-connection-r-next connection) (logand (1+ seq) #xFFFFFFFF))
                (tcp4-send-packet connection ack (tcp-connection-r-next connection) nil
                                  :ack-p t :syn-p t))
               (t
                ;; Aborting connection
                (tcp4-send-packet connection ack seq nil :rst-p t)
                (setf (tcp-connection-state connection) :connection-aborted)
                (detach-tcp-connection connection))))
        (:syn-received
         ;; Pasive open
         (cond ((and (eql flags +tcp4-flag-ack+)
                     (eql seq (tcp-connection-r-next connection))
                     (eql ack (tcp-connection-s-next connection)))
                ;; Remote have sended ACK , connection established
                (setf (tcp-connection-state connection) :established))
               ;; Ignore duplicated SYN packets
               ((and (logtest flags +tcp4-flag-syn+)
                     (eql ack (1- (tcp-connection-s-next connection)))))
               (t
                ;; Aborting connection
                (tcp4-send-packet connection ack seq nil :rst-p t)
                (setf (tcp-connection-state connection) :connection-aborted)
                (detach-tcp-connection connection))))
        (:established
         (if (zerop data-length)
             (when (and (= seq (tcp-connection-r-next connection))
                        (logtest flags +tcp4-flag-fin+))
               ;; Remote have sended FIN and waiting for ACK
               (setf (tcp-connection-state connection) :close-wait
                     (tcp-connection-r-next connection)
                     (logand (+ (tcp-connection-r-next connection) 1)
                             #xFFFFFFFF))
               (tcp4-send-packet connection ack seq nil :ack-p t))
             (tcp4-receive-data connection data-length end header-length packet seq start :established)))
        (:close-wait
         ;; Remote has closed, local can still send data.
         ;; Not much to do here, just waiting for the application to close.
         )
        (:last-ack
         ;; Local closed, waiting for remote to ACK.
         (when (logtest flags +tcp4-flag-ack+)
           ;; Remote have sended ACK , connection closed
           (setf (tcp-connection-state connection) :closed)
           (detach-tcp-connection connection)))
        (:fin-wait-1
         ;; Local closed, waiting for remote to close.
         (if (zerop data-length)
             (when (= seq (tcp-connection-r-next connection))
               (cond ((logtest flags +tcp4-flag-fin+)
                      (setf (tcp-connection-r-next connection)
                            (logand (+ (tcp-connection-r-next connection) 1)
                                    #xFFFFFFFF))
                      (tcp4-send-packet connection
                                        (tcp-connection-s-next connection)
                                        (tcp-connection-r-next connection)
                                        nil)
                      (if (logtest flags +tcp4-flag-ack+)
                          ;; Remote saw our FIN and closed as well.
                          (progn
                            (setf (tcp-connection-state connection) :closed)
                            (detach-tcp-connection connection))
                          ;; Simultaneous close
                          (setf (tcp-connection-state connection) :closing)))
                     ((logtest flags +tcp4-flag-ack+)
                      ;; Remote saw our FIN
                      (setf (tcp-connection-state connection) :fin-wait-2))))
             (tcp4-receive-data connection data-length end header-length packet seq start :fin-wait-1)))
        (:fin-wait-2
         ;; Local closed, still waiting for remote to close.
         (if (zerop data-length)
             (when (and (= seq (tcp-connection-r-next connection))
                        (logtest flags +tcp4-flag-fin+))
               ;; Remote have sended FIN and waiting for ACK
               (setf (tcp-connection-r-next connection)
                     (logand (+ (tcp-connection-r-next connection) 1)
                             #xFFFFFFFF))
               (tcp4-send-packet connection
                                 (tcp-connection-s-next connection)
                                 (tcp-connection-r-next connection)
                                 nil)
               (setf (tcp-connection-state connection) :closed)
               (detach-tcp-connection connection))
             (tcp4-receive-data connection data-length end header-length packet seq start :fin-wait-2)))
        (:closing
         ;; Waiting for ACK
         (when (and (eql seq (tcp-connection-r-next connection))
                    (logtest flags +tcp4-flag-ack+))
           ;; Remote have sended ACK , connection closed
           (detach-tcp-connection connection)
           (setf (tcp-connection-state connection) :closed)))
        (t
         ;; Aborting connection
         (tcp4-send-packet connection ack seq nil :rst-p t)
         (setf (tcp-connection-state connection) :connection-aborted)
         (detach-tcp-connection connection))))
    (mezzano.supervisor:condition-notify (tcp-connection-cvar connection) t)))

(defun tcp4-send-packet (connection seq ack data &key cwr-p ece-p urg-p (ack-p t) psh-p rst-p syn-p fin-p)
  (let* ((source (tcp-connection-local-ip connection))
         (source-port (tcp-connection-local-port connection))
         (packet (assemble-tcp4-packet source source-port
                                       (tcp-connection-remote-ip connection)
                                       (tcp-connection-remote-port connection)
                                       seq ack
                                       (tcp-connection-window-size connection)
                                       data
                                       :cwr-p cwr-p
                                       :ece-p ece-p
                                       :urg-p urg-p
                                       :ack-p ack-p
                                       :psh-p psh-p
                                       :rst-p rst-p
                                       :syn-p syn-p
                                       :fin-p fin-p)))
    (mezzano.network.ip:transmit-ipv4-packet
     source (tcp-connection-remote-ip connection)
     mezzano.network.ip:+ip-protocol-tcp+ packet)))

(defun compute-ip-pseudo-header-partial-checksum (src-ip dst-ip protocol length)
  (+ (logand src-ip #xFFFF)
     (logand (ash src-ip -16) #xFFFF)
     (logand dst-ip #xFFFF)
     (logand (ash dst-ip -16) #xFFFF)
     protocol
     length))

(defun assemble-tcp4-packet (src-ip src-port dst-ip dst-port seq-num ack-num window payload
                             &key cwr-p ece-p urg-p (ack-p t) psh-p rst-p syn-p fin-p)
  "Build a full TCP & IP header."
  (let* ((checksum 0)
         (payload-size (length payload))
         (header (make-array 20 :element-type '(unsigned-byte 8)))
         (packet (list header payload)))
    ;; Assemble the TCP header.
    (setf (ub16ref/be header +tcp4-header-source-port+) src-port
          (ub16ref/be header +tcp4-header-destination-port+) dst-port
          (ub32ref/be header +tcp4-header-sequence-number+) seq-num
          (ub32ref/be header +tcp4-header-acknowledgment-number+) ack-num
          ;; Data offset/header length (5 32-bit words) and flags.
          (ub16ref/be header +tcp4-header-flags-and-data-offset+) (logior #x5000
                                                                          (if fin-p +tcp4-flag-fin+ 0)
                                                                          (if syn-p +tcp4-flag-syn+ 0)
                                                                          (if rst-p +tcp4-flag-rst+ 0)
                                                                          (if psh-p +tcp4-flag-psh+ 0)
                                                                          (if ack-p +tcp4-flag-ack+ 0)
                                                                          (if urg-p +tcp4-flag-urg+ 0)
                                                                          (if ece-p +tcp4-flag-ece+ 0)
                                                                          (if cwr-p +tcp4-flag-cwr+ 0))
          ;; Window.
          (ub16ref/be header +tcp4-header-window-size+) window
          ;; Checksum.
          (ub16ref/be header +tcp4-header-checksum+) 0
          ;; Urgent pointer.
          (ub16ref/be header +tcp4-header-urgent-pointer+) 0)
    ;; Compute the final checksum.
    (setf checksum (compute-ip-pseudo-header-partial-checksum
                    (mezzano.network.ip::ipv4-address-address src-ip)
                    (mezzano.network.ip::ipv4-address-address dst-ip)
                    mezzano.network.ip:+ip-protocol-tcp+
                    (+ (length header) payload-size)))
    (setf checksum (mezzano.network.ip:compute-ip-partial-checksum header 0 nil checksum))
    (setf checksum (mezzano.network.ip:compute-ip-checksum payload 0 nil checksum))
    (setf (ub16ref/be header +tcp4-header-checksum+) checksum)
    packet))

(defun allocate-local-tcp-port ()
  (do ()
      (nil)
    (let ((port (+ (random 32768) 32768)))
      (unless (find port *allocated-tcp-ports*)
        (push port *allocated-tcp-ports*)
        (return port)))))

(defun close-tcp-connection (connection)
  (with-tcp-connection-locked connection
    (ecase (tcp-connection-state connection)
      (:syn-sent
       (setf (tcp-connection-state connection) :closed)
       (tcp4-send-packet connection
                         (tcp-connection-s-next connection)
                         (tcp-connection-r-next connection)
                         nil
                         :rst-p t)
       (detach-tcp-connection connection))
      ((:established :syn-received)
       (setf (tcp-connection-state connection) :fin-wait-1)
       (tcp4-send-packet connection
                         (tcp-connection-s-next connection)
                         (tcp-connection-r-next connection)
                         nil
                         :fin-p t))
      (:close-wait
       (setf (tcp-connection-state connection) :last-ack)
       (tcp4-send-packet connection
                         (tcp-connection-s-next connection)
                         (tcp-connection-r-next connection)
                         nil
                         :fin-p t))
      (:closed))))

(define-condition network-error (error)
  ())

(define-condition connection-error (network-error)
  ((host :initarg :host :reader connection-error-host)
   (port :initarg :port :reader connection-error-port)))

(define-condition connection-aborted (connection-error)
  ())

(define-condition connection-timed-out (connection-error)
  ())

(defun tcp-listen (local-ip local-port)
  (multiple-value-bind (host interface)
      (mezzano.network.ip:ipv4-route local-ip)
    (let* ((source-address (mezzano.network.ip:ipv4-interface-address interface))
           (listener (make-instance 'tcp-listener
                                    :connection nil
                                    :local-port local-port
                                    :local-ip source-address)))
      (mezzano.supervisor:with-mutex (*tcp-listener-lock*)
        (push listener *tcp-listeners*))
      listener)))

(defun tcp-accept (listener &key timeout)
  (mezzano.supervisor:event-wait-for ((tcp-listener-event listener) :timeout timeout)
    (let ((connection
           (mezzano.supervisor:with-mutex ((tcp-listener-lock listener))
             (prog1
                 (pop (tcp-listener-connection listener))
               (when (endp (tcp-listener-connection listener))
                 (setf (mezzano.supervisor:event-state
                        (tcp-listener-event listener))
                       nil))))))
      (if connection
          (tcp4-accept-connection connection)
          nil))))

(defparameter *tcp-connect-timeout* 10)

(defun tcp-connect (ip port)
  (multiple-value-bind (host interface)
      (mezzano.network.ip:ipv4-route ip)
    (let* ((source-port (allocate-local-tcp-port))
           (source-address (mezzano.network.ip:ipv4-interface-address interface))
           (seq (random #x100000000))
           (connection (make-instance 'tcp-connection
                                      :%state :syn-sent
                                      :local-port source-port
                                      :local-ip source-address
                                      :remote-port port
                                      :remote-ip ip
                                      :s-next (logand #xFFFFFFFF (1+ seq))
                                      :r-next 0
                                      :window-size 8192)))
      (mezzano.supervisor:with-mutex (*tcp-connection-lock*)
        (push connection *tcp-connections*))
      (tcp4-send-packet connection seq 0 nil :ack-p nil :syn-p t)
      ;; FIXME: Better timeout mechanism.
      (let ((timeout (+ (get-universal-time) *tcp-connect-timeout*)))
        (loop
          (when (not (eql (tcp-connection-state connection) :syn-sent))
            (when (eql (tcp-connection-state connection) :connection-aborted)
              (error 'connection-aborted
                     :host ip
                     :port port))
            (return))
          (when (> (get-universal-time) timeout)
            (close-tcp-connection connection)
            (error 'connection-timed-out
                   :host ip
                   :port port))
          (sleep 0.01)))
      connection)))

(defun tcp-send (connection data &optional (start 0) end)
  (when (or (eql (tcp-connection-state connection) :established)
            (eql (tcp-connection-state connection) :close-wait))
    (setf end (or end (length data)))
    (let ((mss (tcp-connection-max-seg-size connection)))
      (cond ((>= start end))
            ((> (- end start) mss)
             ;; Send multiple packets.
             (do ((offset start (+ offset mss)))
                 ((>= offset end))
               (tcp-send connection data offset (min (+ offset mss) end))))
            (t ;; Send one packet.
             (with-tcp-connection-locked connection
               (let ((s-next (tcp-connection-s-next connection)))
                 (setf (tcp-connection-s-next connection)
                       (logand (+ s-next (- end start))
                               #xFFFFFFFF))
                 (tcp4-send-packet connection s-next
                                   (tcp-connection-r-next connection)
                                   (if (and (eql start 0)
                                            (eql end (length data)))
                                       data
                                       (subseq data start end))
                                   :psh-p t))))))))

(defclass tcp-octet-stream (sys.gray:fundamental-binary-input-stream
                            sys.gray:fundamental-binary-output-stream)
  ((connection :initarg :connection :reader tcp-stream-connection)
   (current-packet :initform nil :accessor tcp-stream-packet)))

(defclass tcp-stream (sys.gray:fundamental-character-input-stream
                      sys.gray:fundamental-character-output-stream
                      tcp-octet-stream
                      sys.gray:unread-char-mixin)
  ())

(defun refill-tcp-stream-buffer (stream)
  (let ((connection (tcp-stream-connection stream)))
    (when (and (null (tcp-stream-packet stream))
               (tcp-connection-rx-data connection))
      (setf (tcp-stream-packet stream) (pop (tcp-connection-rx-data connection))))))

(defun tcp-connection-closed-p (stream)
  (with-tcp-connection-locked (tcp-stream-connection stream)
    (let ((connection (tcp-stream-connection stream)))
      (refill-tcp-stream-buffer stream)
      (and (null (tcp-stream-packet stream))
           (not (member (tcp-connection-state connection) '(:established :syn-received :syn-sent)))))))

(defmethod sys.gray:stream-listen ((stream tcp-stream))
  (with-tcp-connection-locked (tcp-stream-connection stream)
    (refill-tcp-stream-buffer stream)
    (not (null (tcp-stream-packet stream)))))

(defmethod sys.gray:stream-read-byte ((stream tcp-octet-stream))
  (with-tcp-connection-locked (tcp-stream-connection stream)
    (when (not (refill-tcp-packet-buffer stream))
      (return-from sys.gray:stream-read-byte :eof))
    (let* ((packet (tcp-stream-packet stream))
           (byte (aref (first packet) (second packet))))
      (when (>= (incf (second packet)) (third packet))
        (setf (tcp-stream-packet stream) nil))
      byte)))

(defmethod sys.gray:stream-read-sequence ((stream tcp-stream) sequence &optional (start 0) end)
  (unless end (setf end (length sequence)))
  (let ((n (- end start)))
    (if (and (subtypep (stream-element-type stream) 'character)
             (or (listp sequence)
                 (not (subtypep (array-element-type sequence) 'unsigned-byte))))
        ;; Fall back on generic read-stream for strings.
        (call-next-method)
        (tcp-read-byte-sequence sequence stream start end))))

(defun refill-tcp-packet-buffer (stream)
  (let ((connection (tcp-stream-connection stream)))
    (when (null (tcp-stream-packet stream))
      ;; Wait for data or for the connection to close.
      (mezzano.supervisor:condition-wait-for ((tcp-connection-cvar connection)
                                              (tcp-connection-lock connection))
        (or (tcp-connection-rx-data connection)
            (not (member (tcp-connection-state connection)
                         '(:established :syn-received :syn-sent)))))
      ;; Something may have refilled while we were waiting.
      (when (tcp-stream-packet stream)
        (return-from refill-tcp-packet-buffer t))
      (when (and (null (tcp-connection-rx-data connection))
                 (not (member (tcp-connection-state connection)
                              '(:established :syn-received :syn-sent))))
        (return-from refill-tcp-packet-buffer nil))
      (setf (tcp-stream-packet stream) (pop (tcp-connection-rx-data connection))))
    t))

(defun tcp-read-byte-sequence (sequence stream start end)
  (with-tcp-connection-locked (tcp-stream-connection stream)
    (let ((position start))
      (loop (when (or (>= position end)
                      (not (refill-tcp-packet-buffer stream)))
              (return))
         (let* ((packet (tcp-stream-packet stream))
                (pkt-data (first packet))
                (pkt-offset (second packet))
                (pkt-length (third packet))
                (bytes-to-copy (min (- end position) (- pkt-length pkt-offset))))
           (replace sequence pkt-data
                    :start1 position
                    :start2 pkt-offset
                    :end2 (+ pkt-offset bytes-to-copy))
           (when (>= (incf (second packet) bytes-to-copy) (third packet))
             (setf (tcp-stream-packet stream) nil))
           (incf position bytes-to-copy)))
      position)))

(defmethod sys.gray:stream-read-char ((stream tcp-stream))
  (let ((leader (read-byte stream nil)))
    (unless leader
      (return-from sys.gray:stream-read-char :eof))
    (when (eql leader #x0D)
      (read-byte stream nil)
      (setf leader #x0A))
    (multiple-value-bind (length code-point)
        (sys.net::utf-8-decode-leader leader)
      (when (null length)
        (return-from sys.gray:stream-read-char
          #\REPLACEMENT_CHARACTER))
      (dotimes (i length)
        (let ((byte (read-byte stream nil)))
          (when (or (null byte)
                    (/= (ldb (byte 2 6) byte) #b10))
            (return-from sys.gray:stream-read-char
              #\REPLACEMENT_CHARACTER))
          (setf code-point (logior (ash code-point 6)
                                   (ldb (byte 6 0) byte)))))
      (if (or (> code-point #x0010FFFF)
              (<= #xD800 code-point #xDFFF))
          #\REPLACEMENT_CHARACTER
          (code-char code-point)))))

(defmethod sys.gray:stream-write-byte ((stream tcp-octet-stream) byte)
  (let ((ary (make-array 1 :element-type '(unsigned-byte 8)
                         :initial-element byte)))
    (tcp-send (tcp-stream-connection stream) ary)))

(defmethod sys.gray:stream-write-sequence ((stream tcp-octet-stream) sequence &optional (start 0) end)
  (unless end (setf end (length sequence)))
  (unless (and (zerop start)
               (eql end (length sequence)))
    (setf sequence (subseq sequence start end)))
  (tcp-send (tcp-stream-connection stream) sequence))

(defmethod sys.gray:stream-write-sequence ((stream tcp-stream) sequence &optional (start 0) end)
  (unless end (setf end (length sequence)))
  (cond ((stringp sequence)
         (setf sequence (sys.net::encode-utf-8-string sequence :start start :end end)))
        ((not (and (zerop start)
                   (eql end (length sequence))))
         (setf sequence (subseq sequence start end))))
  (tcp-send (tcp-stream-connection stream) sequence))

(defmethod sys.gray:stream-write-char ((stream tcp-stream) character)
  (sys.gray:stream-write-sequence stream (string character))
  character)

(defmethod close ((stream tcp-octet-stream) &key abort)
  (declare (ignore abort))
  (close-tcp-connection (tcp-stream-connection stream)))

(defmethod open-stream-p ((stream tcp-octet-stream))
  (not (tcp-connection-closed-p stream)))

(defmethod stream-element-type ((stream tcp-octet-stream))
  '(unsigned-byte 8))

(defun tcp-stream-connect (address port &key element-type)
  (cond ((or (not element-type)
             (and (subtypep element-type 'character)
                  (subtypep 'character element-type)))
         (make-instance 'tcp-stream
                        :connection (tcp-connect (sys.net::resolve-address address) port)))
        ((and (subtypep element-type '(unsigned-byte 8))
              (subtypep '(unsigned-byte 8) element-type))
         (make-instance 'tcp-octet-stream
                        :connection (tcp-connect (sys.net::resolve-address address) port)))
        (t
         (error "Unsupported element type ~S" element-type))))
