(in-package #:manardb)

(defun-speedy mtagmap-byte (mtagmap index)
  (declare (type mindex index))
  (d (mtagmap-ptr mtagmap) index))

(defun-speedy (setf mtagmap-byte) (val mtagmap index)
  (declare (type mindex index) (type fixnum val))
  (setf (d (mtagmap-ptr mtagmap) index) (logand #xff val)))

(declaim (ftype (function (mtagmap mindex) word) mtagmap-word))
(defun-speedy mtagmap-word (mtagmap windex)
  (declare (type mindex windex))
  (d (mtagmap-ptr mtagmap) windex word))

(declaim (ftype (function (word mtagmap mindex) word) (setf mtagmap-word)))
(defun-speedy (setf mtagmap-word) (val mtagmap windex)
  (declare (type mindex windex))
  (declare (type (unsigned-byte 64) val))
  (setf (d (mtagmap-ptr mtagmap) windex word) val))

(defmacro mtagmap-next (mtagmap)
  `(mtagmap-word ,mtagmap 0))

(defun-speedy mtagmap-first-index (mtagmap)
  (declare (ignore mtagmap))
  +word-length+)
(defun-speedy mtagmap-last-index (mtagmap)
  (mtagmap-next mtagmap))
(defun-speedy mtagmap-elem-len (mtagmap)
  (mm-metaclass-len (mtagmap-class mtagmap)))
(defun-speedy mtagmap-elem-pos (mtagmap index)
  (/ (- index (mtagmap-first-index mtagmap)) (mtagmap-elem-len mtagmap)))
(defun-speedy mtagmap-elem-pos-to-index (mtagmap pos)
  (+ (mtagmap-first-index mtagmap) (* (mtagmap-elem-len mtagmap) pos)))

(defun mtagmap-count (mtagmap)
  (if (zerop (mtagmap-elem-len mtagmap))
      0
      (/ (- (mtagmap-last-index mtagmap) (mtagmap-first-index mtagmap))
	 (mtagmap-elem-len mtagmap))))

(defun round-up-to-pagesize (bytes)
  (let ((pagesize (osicat-posix:getpagesize)))
    (* pagesize (max 1 (ceiling bytes pagesize)))))

(defun mtagmap-finalize (m)
  (check-type (mtagmap-class m) mm-metaclass)

  (setf (mtagmap-instantiator m) 
	(mm-metaclass-custom-function (mtagmap-class m) 'instantiator)

	(mtagmap-walker m)
	(mm-metaclass-custom-function (mtagmap-class m) 'walker)

	(slot-value (mtagmap-class m) 'mtagmap) m)

  (check-type (mtagmap-instantiator m) function)
  (check-type (mtagmap-walker m) (or null function))

  (when (mtagmap-closed-p m)
    (setf (mtagmap-layout m) (mm-metaclass-slot-layout (mtagmap-class m))))

  (mtagmap-check m))

(defun mtagmap-check (m)
  (cond ((mtagmap-closed-p m)
	 (assert (cffi:null-pointer-p (mtagmap-ptr m)))
	 (assert (zerop (mtagmap-len m))))
	(t
	 (assert (not (cffi:null-pointer-p (mtagmap-ptr m))))
	 (assert (>= (mtagmap-next m) (mtagmap-first-index m)))
	 (assert (>= (mtagmap-len m) (mtagmap-next m)))))

  (let ((class (mtagmap-class m)))
   (when class
     (check-type class mm-metaclass)
     (assert (layout-compatible-p (mtagmap-layout m) (mm-metaclass-slot-layout class)))
     #-(and) (assert (eq (mtagmap (mm-metaclass-tag class)) m))
     #-(and) (assert (eq (mm-metaclass-mtagmap class) m))))
  m)

(defun fd-file-length (fd)
  (osicat-posix:stat-size (osicat-posix:fstat fd)))

(defun mtagmap-file-length (mtagmap)
  (assert (not (mtagmap-closed-p mtagmap)))
  (fd-file-length (mtagmap-fd mtagmap)))

(defun-speedy check-allocate-okay ()
  (assert *mmap-may-allocate*))

(defun check-mmap-truncate-okay ()
  (assert (not (zerop (logand osicat-posix:MAP-SHARED *mmap-sharing*))))
  (check-allocate-okay))

(defun mtagmap-default-filename (mtagmap)
  (mm-metaclass-pathname (mtagmap-class mtagmap)))

(defun mtagmap-open (mtagmap 
		     &key (file (mtagmap-default-filename mtagmap))
		     (min-bytes 0)
		     (sharing *mmap-sharing*)
		     (protection *mmap-protection*)
		     (finalize t))
  (assert (mtagmap-closed-p mtagmap))
  (incf min-bytes +word-length+)
  (setf min-bytes (round-up-to-pagesize min-bytes))

  (when finalize
    (mtagmap-finalize mtagmap))
  (let ((fd (osicat-posix:open file (logior osicat-posix:O-CREAT osicat-posix:O-RDWR))))
    (unwind-protect
	 (let ((bytes (fd-file-length fd)))
	   (when (> min-bytes bytes)
	     (check-mmap-truncate-okay)
	     (osicat-posix:ftruncate fd min-bytes)
	     (setf bytes min-bytes))

	   (assert (>= bytes +word-length+))
	   
	   (let ((ptr (osicat-posix:mmap
					(cffi:null-pointer) bytes
					protection
					sharing
					fd
					0)))
	     (unwind-protect
		  (let ((new-mtagmap (make-mtagmap :fd fd 
					 :ptr ptr
					 :len bytes)))
		    (when (zerop (mtagmap-next new-mtagmap))
		      (setf (mtagmap-next new-mtagmap) +word-length+))
		    (mtagmap-check new-mtagmap)
		    (setf
		     (mtagmap-fd mtagmap) fd
		     (mtagmap-ptr mtagmap) ptr
		     (mtagmap-len mtagmap) bytes
		     fd nil ptr nil))
	       (when ptr 
		 (osicat-posix:munmap ptr bytes)))))
      (when fd 
	(osicat-posix:close fd))))
  mtagmap)

(defun mtagmap-resize (mtagmap new-len)
  (assert (not (mtagmap-closed-p mtagmap)))
  (check-mmap-truncate-okay)
  (symbol-macrolet ((len (mtagmap-len mtagmap)))
    (flet ((trunc ()
	     (osicat-posix:ftruncate (mtagmap-fd mtagmap) new-len))
	   (remap ()
	     (setf (mtagmap-ptr mtagmap)
		   (osicat-posix:mremap (mtagmap-ptr mtagmap) len new-len osicat-posix:MREMAP-MAYMOVE)
		   len new-len)))
      (let (done)
	(unwind-protect
	     (progn
	       (cond ((> len new-len)
		      (remap)
		      (trunc))
		     (t
		      (trunc)
		     (remap)))
	       (setf done t))
	  (unless done
	    (mtagmap-close mtagmap))))))
    
  (mtagmap-check mtagmap))

(defun mtagmap-extend-alloc (mtagmap bytes)
  (check-type bytes mindex)
  (let ((len (mtagmap-len mtagmap)))
    (let ((next (mtagmap-next mtagmap)) (new-len (* 2 len)))
      (assert (> len 0))
      (assert (>= len next))
      (check-type next mindex)
      (mtagmap-check mtagmap)
      (loop while (> (+ next bytes) new-len)
	    do (setf new-len (* 2 new-len)))
      (mtagmap-resize mtagmap new-len))))

(defun-speedy mtagmap-alloc (mtagmap bytes)
  (declare (type mindex bytes))
  (check-allocate-okay)
  (symbol-macrolet ((len (mtagmap-len mtagmap)))
    (when (zerop len)
      (mtagmap-open mtagmap))

    (let ((next (mtagmap-next mtagmap)))
      (when (> (+ next bytes) len)
	(mtagmap-extend-alloc mtagmap bytes))
      (incf (mtagmap-next mtagmap) bytes)
      next)))

(defun mtagmap-check-read (mtagmap)
  (loop for i below (mtagmap-len mtagmap)
	summing (mtagmap-byte mtagmap i)))

(defun mtagmap-check-invert (mtagmap)
  (loop for i below (mtagmap-len mtagmap)
	for c = (mtagmap-byte mtagmap i)
	do (setf (mtagmap-byte mtagmap i) (lognot c))))

(defun mtagmap-check-write (mtagmap)
  (mtagmap-check-invert mtagmap)
  (mtagmap-check-invert mtagmap))

(defun-speedy mtagmap-closed-p (mtagmap)
  (= -1 (mtagmap-fd mtagmap)))

(defun mtagmap-close (mtagmap)
  (check-type mtagmap mtagmap)
  (let ((fd (mtagmap-fd mtagmap))
	(ptr (mtagmap-ptr mtagmap))
	(len (mtagmap-len mtagmap)))

    (mtagmap-detach mtagmap)

    (unwind-protect
	 (unless (cffi:null-pointer-p ptr)
	   (osicat-posix:munmap ptr len))
      (unless (minusp fd)
	(osicat-posix:close fd))))
  mtagmap)

(defun mtagmap-detach (mtagmap)
  (setf (mtagmap-fd mtagmap) -1
	(mtagmap-len mtagmap) 0
	(mtagmap-ptr mtagmap) (cffi:null-pointer)))


(defun mtagmap-shrink (mtagmap)
  (assert (not (mtagmap-closed-p mtagmap)))
  (mtagmap-check mtagmap)
  (let* ((next (mtagmap-next mtagmap))
	 (bytes (round-up-to-pagesize next)) (file-len (mtagmap-file-length mtagmap)))
    (unless (= bytes file-len)
      (assert (> file-len bytes))
      (assert (>= bytes next))
      (unless (= next bytes)
	(osicat-posix:memset (cffi:inc-pointer (mtagmap-ptr mtagmap) next)
			     0 (- bytes next)))
      (mtagmap-resize mtagmap bytes))))

(defun mtagmap-schema (mtagmap)
  (let ((class (mtagmap-class mtagmap)))
    (mm-metaclass-schema class)))
