;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; CLOG - The Common Lisp Omnificent GUI                                 ;;;;
;;;; (c) 2020-2021 David Botton                                            ;;;;
;;;; License BSD 3 Clause                                                  ;;;;
;;;;                                                                       ;;;;
;;;; clog-connection.lisp                                                  ;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Exports - clog-connection
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


(mgl-pax:define-package :clog-connection
  (:documentation "The Common List Omnificent GUI - Connection")
  (:use #:cl #:mgl-pax))

(in-package :clog-connection)

(defsection @clog-connection (:title "CLOG Connection")
  "Low level connectivity to the web client and boot file 
script."

  "CLOG system startup and shutdown"

  (*verbose-output* variable)

  (initialize          function)
  (shutdown-clog       function)
  (set-on-connect      function)
  (get-connection-data function)

  "CLOG system utilities"
  
  (escape-string function)
  
  "CLOG connections"
  
  (execute     function)
  (query       function)
  (validp      function)
  (cclose      function)
  (shutdown    function)
  (put         function)
  (put-line    function)
  (new-line    function)
  (alert-box   function)
  (generate-id function))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Implemetation - clog-connection
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar *verbose-output* nil "Verbose server output (default false)")

(defvar *app*                nil "Clack 'app' middle-ware")
(defvar *client-handler*     nil "Clack 'handler' for socket traffic")
(defvar *on-connect-handler* nil "New connection event handler.")

(defvar *new-id* 0 "Last issued connection or script IDs")

(defvar *connections*     (make-hash-table) "Connections to IDs")
(defvar *connection-ids*  (make-hash-table) "IDs to connections")
(defvar *connection-data* (make-hash-table) "Connection based data")

(defvar *connection-lock* (bordeaux-threads:make-lock)
  "Protect the connection hash tables")
(defvar *queries-lock*    (bordeaux-threads:make-lock)
  "Protect query hash tables")
(defvar *id-lock*         (bordeaux-threads:make-lock)
  "Protect new-id variable.")

(defvar *queries*        (make-hash-table) "Query ID to Answers")
(defvar *queries-sems*   (make-hash-table) "Query ID to semiphores")
(defvar *query-time-out* 3 "Number of seconds to timeout waiting for a query")

;;;;;;;;;;;;;;;;;
;; generate-id ;;
;;;;;;;;;;;;;;;;;

(defun generate-id ()
  "Generate unique ids for use in connections and sripts."
  ;; needs mutex or atomic
  (bordeaux-threads:with-lock-held (*id-lock*) (incf *new-id*)))

;;;;;;;;;;;;;;;;;;;;
;; get-connection ;;
;;;;;;;;;;;;;;;;;;;;

(defun get-connection (connection-id)
  "Return the connection associated with CONNECITION-ID. (Private)"
  (gethash connection-id *connection-ids*))

;;;;;;;;;;;;;;;;;;;;;;;;;
;; get-connection-data ;;
;;;;;;;;;;;;;;;;;;;;;;;;;

(defun get-connection-data (connection-id)
  "Return the connecton data associated with the CONNECTION-ID a
hash test: #'equal."
  (gethash connection-id *connection-data*))


;;;;;;;;;;;;;;;;
;; prep-query ;;
;;;;;;;;;;;;;;;;

(defun prep-query (id default-answer)
  "Setup up a query to be received from a script identified by ID an returning
with DEFAULT-ANSWER in case of a time out. (Private)"
  (bordeaux-threads:with-lock-held (*queries-lock*)
    (setf (gethash id *queries-sems*) (bordeaux-threads:make-semaphore))
    (setf (gethash id *queries*) default-answer)))

;;;;;;;;;;;;;;;;;;;;;
;; wait-for-answer ;;
;;;;;;;;;;;;;;;;;;;;;

(defun wait-for-answer (id &key (timeout *query-time-out*))
  "Block after prep-query and sending the query script with ID and TIMEOUT with
the default answer. (Private)"
  (bordeaux-threads:wait-on-semaphore (gethash id *queries-sems*) :timeout timeout)
  (let ((answer (gethash id *queries*)))
    (bordeaux-threads:with-lock-held (*queries-lock*)
      (remhash id *queries*)
      (remhash id *queries-sems*))
    answer))

;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; handle-new-connection ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun handle-new-connection (connection id)
  (cond (id
	 (format t "Reconnection id - ~A to ~A~%" id connection)
	 (bordeaux-threads:with-lock-held (*connection-lock*)
	   (setf (gethash id *connection-ids*) connection)
	   (setf (gethash connection *connections*) id)))
	(t
	 (setf id (generate-id))
	 (bordeaux-threads:with-lock-held (*connection-lock*)
	   (setf (gethash connection *connections*) id)
	   (setf (gethash id *connection-ids*) connection)
	   (setf (gethash id *connection-data*) (make-hash-table :test #'equal))
	   (setf (gethash "connection-id" (get-connection-data id)) id))
	 (format t "New connection id - ~A - ~A~%" id connection)
	 (websocket-driver:send connection
				(format nil "clog['connection_id']=~A" id))
	 (bordeaux-threads:make-thread
	  (lambda ()
	    (funcall *on-connect-handler* id))))))

;;;;;;;;;;;;;;;;;;;;
;; handle-message ;;
;;;;;;;;;;;;;;;;;;;;

(defun handle-message (connection message)
  (let ((id (gethash connection *connections*))
	(ml (ppcre:split ":" message :limit 2)))
    (cond ((equal (first ml) "0")
	   (when *verbose-output*
	     (format t "~A Ping~%" id)))
	  ((equal (first ml) "E")
	   (let ((em (ppcre:split "-" (second ml) :limit 2)))
	     (when *verbose-output*
	       (format t "Channel ~A Hook ~A Data ~A~%"
		       id (first em) (second em)))
	     (funcall (gethash (first em) (get-connection-data id)) (second em))))
	  (t
	   (when *verbose-output*
	     (format t "~A ~A = ~A~%" id (first ml) (second ml)))
	   (bordeaux-threads:with-lock-held (*queries-lock*)
	     (setf (gethash (parse-integer (first ml)) *queries*) (second ml)))
	   (bordeaux-threads:signal-semaphore
	    (gethash (parse-integer (first ml)) *queries-sems*))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; handle-close-connection ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun handle-close-connection (connection)
  (let ((id (gethash connection *connections*)))
    (when id
      (when *verbose-output*
	(format t "Connection id ~A has closed. ~A~%" id connection))
      (bordeaux-threads:with-lock-held (*connection-lock*)
	(remhash id *connection-data*)
	(remhash id *connection-ids*)
	(remhash connection *connections*)))))

;;;;;;;;;;;;;;;;;
;; clog-server ;;
;;;;;;;;;;;;;;;;;

(defun clog-server (env)
  (let ((ws (websocket-driver:make-server env)))
    (websocket-driver:on :open ws
                         (lambda ()
			   (let ((id (getf env :query-string)))
			     (when (typep id 'string)
			       (setf id (parse-integer id :junk-allowed t)))
			     (handle-new-connection ws id))))
    
    (websocket-driver:on :message ws
                         (lambda (msg) (handle-message ws msg)))

    (websocket-driver:on :close ws
                         (lambda (&key code reason)
                           (declare (ignore code reason))
                           (handle-close-connection ws)))
    (lambda (responder)
      (declare (ignore responder))
      (websocket-driver:start-connection ws))))

;;;;;;;;;;;;;;;;
;; initialize ;;
;;;;;;;;;;;;;;;;

(defun initialize (on-connect-handler
		   &key
		     (host           "0.0.0.0")
		     (port           8080)
		     (boot-file      "/boot.html")
		     (static-root    #P"./static-files/"))
  "Inititalze CLOG on a socket using HOST and PORT to serve BOOT-FILE as 
the default route to establish web-socket connections and static files
located at STATIC-ROOT."
  (set-on-connect on-connect-handler)  
  (setf *app*
	(lack:builder
	 (:static :path (lambda (path)
			  (cond ((ppcre:scan "^(?:/clog$)" path) nil)
				((equal path "/") boot-file)
				(t path)))
		  :root static-root)
	 (lambda (env)
	   (clog-server env))))
  (setf *client-handler* (clack:clackup *app* :address host :port port))
  (format t "HTTP listening on : ~A:~A~%" host port)
  (format t "HTML Root         : ~A~%"    static-root)
  (format t "Boot file default : ~A~%"    boot-file))

;;;;;;;;;;;;;;;;;;;
;; shutdown-clog ;;
;;;;;;;;;;;;;;;;;;;

(defun shutdown-clog ()
  "Shutdown CLOG."
  (clack:stop *client-handler*)
  (bordeaux-threads:with-lock-held (*connection-lock*)
    (clrhash *connection-data*)
    (clrhash *connections*)
    (clrhash *connection-ids*))
  (setf *app* nil)
  (setf *client-handler* nil))

;;;;;;;;;;;;;;;;;;;;
;; set-on-connect ;;
;;;;;;;;;;;;;;;;;;;;

(defun set-on-connect (on-connect-handler)
  "Change the ON-CONNECTION-HANDLER set during Initialize."
  (setf *on-connect-handler* on-connect-handler))

;;;;;;;;;;;;;;;;;;;
;; escape-string ;;
;;;;;;;;;;;;;;;;;;;

(defun escape-string (str)
  "Escape STR for sending to browser script."
  (let ((res))
    (setf res (ppcre:regex-replace-all "\\x22" str "\\x22"))
    (setf res (ppcre:regex-replace-all "\\x27" res "\\x27"))
    (setf res (ppcre:regex-replace-all "\\x0A" res "\\x0A"))
    (setf res (ppcre:regex-replace-all "\\x0D" res "\\x0D"))
    res))

;;;;;;;;;;;;;
;; execute ;;
;;;;;;;;;;;;;

(defun execute (connection-id message)
  "Execute SCRIPT on CONNECTION-ID, disregard return value."
  (let ((con (get-connection connection-id)))
    (when con
      (websocket-driver:send con message))))

;;;;;;;;;;;
;; query ;;
;;;;;;;;;;;

(defun query (connection-id script)
  "Execute SCRIPT on CONNECTION-ID, return value."
  (let ((uid (generate-id)))
    (prep-query uid nil)
    (execute connection-id
	     (format nil "ws.send (\"~A:\"+eval(\"~A\"));"
		     uid
		     (escape-string script)))
    (wait-for-answer uid)))

;;;;;;;;;;;;
;; validp ;;
;;;;;;;;;;;;

(defun validp (connection-id)
  "Check if CONNECTION-ID is valid."
  (if (get-connection connection-id)
      t
      nil))

;;;;;;;;;;;;
;; cclose ;;
;;;;;;;;;;;;

(defun cclose (connection-id)
  "Close connection to CONNECTION-ID. The boot file may try to reistablish
 connectivity."
  (execute connection-id "ws.close()"))

;;;;;;;;;;;;;;
;; shutdown ;;
;;;;;;;;;;;;;;

(defun shutdown (connection-id)
  "Shutdown connection to CONNECTION-ID. The boot file may not try to
reistablish connectivity."
  (execute connection-id "Shutdown_ws(event.reason='user')"))

;;;;;;;;;
;; put ;;
;;;;;;;;;

(defun put (connection-id text)
  "Write TEXT to document object of CONNECTION-ID with out new line."
  (execute connection-id
	   (format nil "document.write('~A');" (escape-string text))))

;;;;;;;;;;;;;;
;; put-line ;;
;;;;;;;;;;;;;;

(defun put-line (connection-id text)
  "Write TEXT to document object of CONNECTION-ID with new line and
HTML <br />."
  (execute connection-id
	   (format nil "document.writeln('~A<br />');" (escape-string text))))

;;;;;;;;;;;;;;
;; new-line ;;
;;;;;;;;;;;;;;

(defun new-line (connection-id)
  "Write a new line raw to document object of CONNECTION-ID with a <br />."
  (execute connection-id (format nil "document.writeln('<br />');")))

;;;;;;;;;;;;;;;
;; alert-box ;;
;;;;;;;;;;;;;;;

(defun alert-box (connection-id message)
  "Create an alert box on CONNECTION-ID with MESSAGE"
  (execute connection-id (format nil "alert('~A');" (escape-string message))))

