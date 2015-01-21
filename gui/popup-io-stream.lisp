(defpackage :mezzanine.gui.popup-io-stream
  (:use :cl :mezzanine.gui.font)
  (:export #:popup-io-stream))

(in-package :mezzanine.gui.popup-io-stream)

(defclass popup-io-stream (mezzanine.line-editor:line-edit-mixin
                           sys.gray:fundamental-character-input-stream
                           sys.gray:fundamental-character-output-stream)
  ((%fifo :reader fifo)
   (%framebuffer :reader framebuffer)
   (%closed :accessor window-closed)
   (%break-requested :initform nil :accessor break-requested)
   ;; Transient window stuff.
   (%window :reader window)
   (%thread :reader thread)
   (%frame-dirty-p :initform nil :accessor frame-dirty-p)
   ;; The read-char typeahead buffer.
   (%input :reader input-buffer)
   (%waiting-input-count :accessor waiting-input-count)
   ;; Frame and display.
   (%frame :reader frame)
   (%text-widget :reader display)
   ;; Protecting stuff.
   (%lock :reader lock)
   (%cvar :reader cvar)))

(defclass damage ()
  ((%x :initarg :x :reader x)
   (%y :initarg :y :reader y)
   (%width :initarg :width :reader width)
   (%height :initarg :height :reader height)))

(defmethod initialize-instance :after ((instance popup-io-stream) &key (width 640) (height 480) title &allow-other-keys)
  ;; Do this early so the initial text-widget damage even won't open the window.
  (setf (window-closed instance) nil
        (slot-value instance '%fifo) (mezzanine.supervisor:make-fifo 50)
        (slot-value instance '%lock) (mezzanine.supervisor:make-mutex "Popup Stream Lock")
        (slot-value instance '%cvar) (mezzanine.supervisor:make-condition-variable "Popup Stream Cvar"))
  (let* ((framebuffer (make-array (list height width) :element-type '(unsigned-byte 32)))
         (frame (make-instance 'mezzanine.gui.widgets:frame
                               :framebuffer framebuffer
                               :title (string (or title (format nil "~S" instance)))
                               :close-button-p t
                               :damage-function (lambda (&rest args)
                                                  (declare (ignore args))
                                                  (setf (frame-dirty-p instance) t))))
         ;; It's actually ok to hold onto this font, even though WITH-FONT drops the reference.
         ;; This just means that the font might not be shared with other programs.
         ;; Sigh...
         (term (with-font (font *default-monospace-font* *default-monospace-font-size*)
                 (make-instance 'mezzanine.gui.widgets:text-widget
                                :font font
                                :framebuffer framebuffer
                                :x-position (nth-value 0 (mezzanine.gui.widgets:frame-size frame))
                                :y-position (nth-value 2 (mezzanine.gui.widgets:frame-size frame))
                                :width (- width
                                          (nth-value 0 (mezzanine.gui.widgets:frame-size frame))
                                          (nth-value 1 (mezzanine.gui.widgets:frame-size frame)))
                                :height (- height
                                           (nth-value 2 (mezzanine.gui.widgets:frame-size frame))
                                           (nth-value 3 (mezzanine.gui.widgets:frame-size frame)))
                                :damage-function (lambda (&rest args) (apply #'damage instance args))))))
    (setf (slot-value instance '%framebuffer) framebuffer
          (slot-value instance '%closed) t
          (slot-value instance '%window) nil
          (slot-value instance '%thread) nil
          ;; Use a supervisor FIFO for this because I'm too lazy to implement a normal FIFO.
          (slot-value instance '%input) (mezzanine.supervisor:make-fifo 500 :element-type 'character)
          (slot-value instance '%frame) frame
          (slot-value instance '%text-widget) term
          (slot-value instance '%waiting-input-count) 0)))

(defgeneric dispatch-event (stream event))

(defmethod dispatch-event (window (event mezzanine.gui.compositor:window-activation-event))
  (setf (mezzanine.gui.widgets:activep (frame window)) (mezzanine.gui.compositor:state event))
  (mezzanine.gui.widgets:draw-frame (frame window))
  (dispatch-event window
                  (make-instance 'damage
                                 :x 0
                                 :y 0
                                 :width (mezzanine.gui.compositor:width (window window))
                                 :height (mezzanine.gui.compositor:height (window window)))))

(defmethod dispatch-event (window (event mezzanine.gui.compositor:key-event))
  ;; should filter out strange keys?
  (when (not (mezzanine.gui.compositor:key-releasep event))
    (mezzanine.supervisor:with-mutex ((lock window))
      (cond ((and (eql (mezzanine.gui.compositor:key-key event) #\Esc)
                  (member :control (mezzanine.gui.compositor:key-modifier-state event)))
             (setf (break-requested window) t))
            (t (mezzanine.supervisor:fifo-push (if (mezzanine.gui.compositor:key-modifier-state event)
                                                   ;; Force character to uppercase when a modifier key is active, gets
                                                   ;; around weirdness in how character names are processed.
                                                   ;; #\C-a and #\C-A both parse as the same character (C-LATIN_CAPITAL_LETTER_A).
                                                   (sys.int::make-character (char-code (char-upcase (mezzanine.gui.compositor:key-key event)))
                                                                            :control (find :control (mezzanine.gui.compositor:key-modifier-state event))
                                                                            :meta (find :meta (mezzanine.gui.compositor:key-modifier-state event))
                                                                            :super (find :super (mezzanine.gui.compositor:key-modifier-state event))
                                                                            :hyper (find :hyper (mezzanine.gui.compositor:key-modifier-state event)))
                                                   (mezzanine.gui.compositor:key-key event))
                                               (input-buffer window) nil)))
      (mezzanine.supervisor:condition-notify (cvar window)))))

(defmethod dispatch-event (window (event mezzanine.gui.compositor:mouse-event))
  (mezzanine.gui.widgets:frame-mouse-event (frame window) event)
  (when (frame-dirty-p window)
    (setf (frame-dirty-p window) nil)
    (dispatch-event window
                    (make-instance 'damage
                                   :x 0
                                   :y 0
                                   :width (mezzanine.gui.compositor:width (window window))
                                   :height (mezzanine.gui.compositor:height (window window))))))

(defmethod dispatch-event (window (event mezzanine.gui.compositor:window-close-event))
  (when (eql (window window) (mezzanine.gui.compositor:window event))
    (throw 'mezzanine.supervisor::terminate-thread nil)))

(defmethod dispatch-event (window (event damage))
  (mezzanine.gui:bitblt (height event) (width event)
                        (framebuffer window)
                        (y event) (x event)
                        (mezzanine.gui.compositor:window-buffer (window window))
                        (y event) (x event))
  (mezzanine.gui.compositor:damage-window (window window)
                                          (x event) (y event)
                                          (width event) (height event)))


(defun window-thread (stream)
  (mezzanine.gui.compositor:with-window (window (fifo stream) (array-dimension (framebuffer stream) 1) (array-dimension (framebuffer stream) 0)
                                                :initial-z-order :below-current)
    (setf (slot-value stream '%window) window
          (mezzanine.gui.widgets:activep (frame stream)) nil)
    (mezzanine.gui.widgets:draw-frame (frame stream))
    (dispatch-event stream
                    (make-instance 'damage
                                   :x 0
                                   :y 0
                                   :width (mezzanine.gui.compositor:width window)
                                   :height (mezzanine.gui.compositor:height window)))
    (unwind-protect
         (loop
            (handler-case
                (dispatch-event stream (mezzanine.supervisor:fifo-pop (fifo stream)))
              (mezzanine.gui.widgets:close-button-clicked ()
                (mezzanine.supervisor:with-mutex ((lock stream))
                  (when (zerop (waiting-input-count stream))
                    (setf (slot-value stream '%window) nil
                          (slot-value stream '%thread) nil
                          (window-closed stream) t)
                    (return))))
              (error (c)
                (ignore-errors
                  (format t "~&Error ~A in popup stream.~%" c)))))
      (mezzanine.supervisor:with-mutex ((lock stream))
        (when (eql (slot-value stream '%window) window)
          (setf (slot-value stream '%window) nil
                (slot-value stream '%thread) nil
                (window-closed stream) t))))))

(defun open-window (stream)
  (when (window-closed stream)
    (setf (window-closed stream) nil
          (slot-value stream '%thread) (mezzanine.supervisor:make-thread (lambda () (window-thread stream))
                                                                         :name (format nil "~S Window Thread" stream)))))

(defun damage (stream x y width height)
  (open-window stream)
  (mezzanine.supervisor:fifo-push (make-instance 'damage
                                                 :x x
                                                 :y y
                                                 :width width
                                                 :height height)
                                  (fifo stream)))

(defun check-for-break (stream)
  (when (break-requested stream)
    (setf (break-requested stream) nil)
    (break)))

(defmethod sys.gray:stream-read-char ((stream popup-io-stream))
  (loop
     (check-for-break stream)
     (unwind-protect
          (progn
            (setf (mezzanine.gui.widgets:cursor-visible (display stream)) t)
            (mezzanine.supervisor:with-mutex ((lock stream))
              ;; Examine input stream.
              (let ((ch (mezzanine.supervisor:fifo-pop (input-buffer stream) nil)))
                (when ch
                  (return ch)))
              ;; No characters ready, open the window and wait for one.
              (open-window stream)
              ;; Wait.
              (incf (waiting-input-count stream))
              (mezzanine.supervisor:condition-wait (cvar stream) (lock stream))
              (decf (waiting-input-count stream))))
       (setf (mezzanine.gui.widgets:cursor-visible (display stream)) nil))))

(defmethod sys.gray:stream-read-char-no-hang ((stream popup-io-stream))
  (check-for-break stream)
  (mezzanine.supervisor:with-mutex ((lock stream))
    ;; Examine input stream.
    (mezzanine.supervisor:fifo-pop (input-buffer stream) nil)))

;;; Forward stream stuff on to the display.

(defmethod sys.gray:stream-terpri ((stream popup-io-stream))
  (check-for-break stream)
  (mezzanine.supervisor:with-mutex ((lock stream))
    (sys.gray:stream-terpri (display stream))))

(defmethod sys.gray:stream-write-char ((stream popup-io-stream) character)
  (check-for-break stream)
  (mezzanine.supervisor:with-mutex ((lock stream))
    (sys.gray:stream-write-char (display stream) character)))

(defmethod sys.gray:stream-start-line-p ((stream popup-io-stream))
  (check-for-break stream)
  (mezzanine.supervisor:with-mutex ((lock stream))
    (sys.gray:stream-start-line-p (display stream))))

(defmethod sys.gray:stream-line-column ((stream popup-io-stream))
  (check-for-break stream)
  (mezzanine.supervisor:with-mutex ((lock stream))
    (sys.gray:stream-line-column (display stream))))

(defmethod sys.int::stream-cursor-pos ((stream popup-io-stream))
  (check-for-break stream)
  (mezzanine.supervisor:with-mutex ((lock stream))
    (sys.int::stream-cursor-pos (display stream))))

(defmethod sys.int::stream-move-to ((stream popup-io-stream) x y)
  (check-for-break stream)
  (mezzanine.supervisor:with-mutex ((lock stream))
    (sys.int::stream-move-to (display stream) x y)))

(defmethod sys.int::stream-character-width ((stream popup-io-stream) character)
  (check-for-break stream)
  (mezzanine.supervisor:with-mutex ((lock stream))
    (sys.int::stream-character-width (display stream) character)))

(defmethod sys.int::stream-compute-motion ((stream popup-io-stream) string &optional (start 0) end initial-x initial-y)
  (check-for-break stream)
  (mezzanine.supervisor:with-mutex ((lock stream))
    (sys.int::stream-compute-motion (display stream) string start end initial-x initial-y)))

(defmethod sys.int::stream-clear-between ((stream popup-io-stream) start-x start-y end-x end-y)
  (check-for-break stream)
  (mezzanine.supervisor:with-mutex ((lock stream))
    (sys.int::stream-clear-between (display stream) start-x start-y end-x end-y)))