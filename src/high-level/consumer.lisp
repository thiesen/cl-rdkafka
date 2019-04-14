;;; Copyright (C) 2018-2019 Sahil Kang <sahil.kang@asilaycomputing.com>
;;;
;;; This file is part of cl-rdkafka.
;;;
;;; cl-rdkafka is free software: you can redistribute it and/or modify
;;; it under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.
;;;
;;; cl-rdkafka is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with cl-rdkafka.  If not, see <http://www.gnu.org/licenses/>.

(in-package #:cl-rdkafka)

(defclass consumer ()
  ((rd-kafka-consumer
    :documentation "Pointer to rd_kafka_t struct.")
   (key-serde
    :initarg :key-serde
    :initform nil
    :documentation "Function to map byte vector to object, or nil for bytes.")
   (value-serde
    :initarg :value-serde
    :initform nil
    :documentation "Function to map byte vector to object, or nil for bytes.")))

(defgeneric subscribe (consumer topics))

(defgeneric unsubscribe (consumer))

(defgeneric subscription (consumer))

(defgeneric poll (consumer timeout-ms))

(defgeneric commit (consumer &optional topic+partitions))

(defgeneric committed (consumer &optional topic+partitions))

(defgeneric assignment (consumer))

(defgeneric assign (consumer topic+partitions))

(defmethod initialize-instance :after ((consumer consumer)
				       &key conf)
  (with-slots (rd-kafka-consumer) consumer
    (cffi:with-foreign-object (errstr :char +errstr-len+)
      (setf rd-kafka-consumer (cl-rdkafka/ll:rd-kafka-new
			       cl-rdkafka/ll:rd-kafka-consumer
			       (make-conf conf)
			       errstr
			       +errstr-len+))
      (when (cffi:null-pointer-p rd-kafka-consumer)
	(error "~&Failed to allocate new consumer: ~A"
	       (cffi:foreign-string-to-lisp errstr :max-chars +errstr-len+))))
    (tg:finalize
     consumer
     (lambda ()
       (cl-rdkafka/ll:rd-kafka-consumer-close rd-kafka-consumer)
       (cl-rdkafka/ll:rd-kafka-destroy rd-kafka-consumer)))))

(defun topic-names->topic+partitons (topics)
  (loop
     for i below (length topics)
     for name = (elt topics i)
     for topic+partition = (make-instance 'topic+partition :topic name)
     collect topic+partition))

(defmethod subscribe ((consumer consumer) topics)
  (with-slots (rd-kafka-consumer) consumer
    (let* ((topic+partitions
	    (topic-names->topic+partitons topics))
	   (rd-kafka-list
	    (topic+partitions->rd-kafka-list topic+partitions))
	   (err
	    (cl-rdkafka/ll:rd-kafka-subscribe rd-kafka-consumer rd-kafka-list)))
      (cl-rdkafka/ll:rd-kafka-topic-partition-list-destroy rd-kafka-list)
      (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
	(error "~&Failed to subscribe to topics with error: ~A"
	       (error-description err))))))

(defmethod unsubscribe ((consumer consumer))
  (with-slots (rd-kafka-consumer) consumer
    (let ((err (cl-rdkafka/ll:rd-kafka-unsubscribe rd-kafka-consumer)))
      (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
	(error "~&Failed to unsubscribe consumer with error: ~A"
	       (error-description err))))))

(defun get-topic+partitions (rd-kafka-consumer)
  (cffi:with-foreign-object (list-pointer :pointer)
    (let ((err (cl-rdkafka/ll:rd-kafka-subscription
		rd-kafka-consumer
		list-pointer)))
      (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
	(error "~&Failed to get subscription with error: ~A"
	       (error-description err)))
      (let* ((*list-pointer (cffi:mem-ref list-pointer :pointer))
	     (topic+partitions (rd-kafka-list->topic+partitions
				*list-pointer)))
	(cl-rdkafka/ll:rd-kafka-topic-partition-list-destroy *list-pointer)
	topic+partitions))))

(defmethod subscription ((consumer consumer))
  (with-slots (rd-kafka-consumer) consumer
    (let ((topics (get-topic+partitions rd-kafka-consumer)))
      (loop
	 for i below (length topics)
	 for topic+partition = (elt topics i)
	 for name = (topic topic+partition)
	 do (setf (elt topics i) name))
      topics)))

(defmethod poll ((consumer consumer) (timeout-ms integer))
  (with-slots (rd-kafka-consumer key-serde value-serde) consumer
    (let ((rd-kafka-message (cl-rdkafka/ll:rd-kafka-consumer-poll
			     rd-kafka-consumer
			     timeout-ms)))
      (unless (cffi:null-pointer-p rd-kafka-message)
	(let ((message (make-instance 'message
				      :rd-kafka-message rd-kafka-message
				      :key-serde key-serde
				      :value-serde value-serde)))
	  (cl-rdkafka/ll:rd-kafka-message-destroy rd-kafka-message)
	  message)))))

(defun %commit (rd-kafka-consumer rd-kafka-topic-partition-list)
  (make-instance
   'future
   :thunk (lambda ()
	    (unwind-protect
		 (let ((err (cl-rdkafka/ll:rd-kafka-commit
			     rd-kafka-consumer
			     rd-kafka-topic-partition-list
			     0)))
		   (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
		     (make-instance 'kafka-error :rd-kafka-resp-err err)))
	      (unless (cffi:null-pointer-p rd-kafka-topic-partition-list)
		(cl-rdkafka/ll:rd-kafka-topic-partition-list-destroy
		 rd-kafka-topic-partition-list))))))

(defmethod commit ((consumer consumer) &optional topic+partitions)
  "Commit offsets and return a future containing either an error or nil.

If topic+partitions is nil (the default) then the current assignment is
committed."
  (with-slots (rd-kafka-consumer) consumer
    (if topic+partitions
	(%commit rd-kafka-consumer
		 (topic+partitions->rd-kafka-list topic+partitions))
	(%commit rd-kafka-consumer
		 (cffi:null-pointer)))))

(defun %assignment (rd-kafka-consumer)
  (cffi:with-foreign-object (rd-list :pointer)
    (let ((err (cl-rdkafka/ll:rd-kafka-assignment
		rd-kafka-consumer
		rd-list)))
      (if (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
	  (let ((*rd-list (cffi:mem-ref rd-list :pointer)))
	    (values *rd-list t))
	  (values (make-instance 'kafka-error :rd-kafka-resp-err err)
		  nil)))))

(defmethod assignment ((consumer consumer))
  "Get a sequence of assigned topic+partitions."
  (with-slots (rd-kafka-consumer) consumer
    (multiple-value-bind (rd-list success?) (%assignment rd-kafka-consumer)
      (if success?
	  (let ((topic+partitions (rd-kafka-list->topic+partitions rd-list)))
	    (cl-rdkafka/ll:rd-kafka-topic-partition-list-destroy rd-list)
	    topic+partitions)
	  (error "~&Failed to get assignment with error: ~A"
		 (error-description rd-list))))))

(defun %committed (rd-kafka-consumer rd-list)
  (let ((err (cl-rdkafka/ll:rd-kafka-committed
	      rd-kafka-consumer
	      rd-list
	      60000)))
    (let ((topic+partitions (rd-kafka-list->topic+partitions rd-list)))
      (cl-rdkafka/ll:rd-kafka-topic-partition-list-destroy rd-list)
      (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
	(error "~&Failed to get committed offsets with error: ~A"
	       (error-description err)))
      topic+partitions)))

(defmethod committed ((consumer consumer) &optional topic+partitions)
  "Get a sequence of committed topic+partitions.

If topic+partitions is nil (the default) then info about the current
assignment is returned."
  (with-slots (rd-kafka-consumer) consumer
    (if topic+partitions
	(%committed rd-kafka-consumer
		    (topic+partitions->rd-kafka-list topic+partitions))
	(multiple-value-bind (rd-list success?) (%assignment rd-kafka-consumer)
	  (if success?
	      (%committed rd-kafka-consumer rd-list)
	      (error "~&Failed to get committed offsets with error: ~A"
		     (error-description rd-list)))))))

(defmethod assign ((consumer consumer) topic+partitions)
  "Assign partitions to consumer.

Returns nil on success or a kafka-error on failure."
  (with-slots (rd-kafka-consumer) consumer
    (let* ((rd-list (topic+partitions->rd-kafka-list topic+partitions))
	   (err (cl-rdkafka/ll:rd-kafka-assign rd-kafka-consumer rd-list)))
      (cl-rdkafka/ll:rd-kafka-topic-partition-list-destroy rd-list)
      (unless (eq err cl-rdkafka/ll:rd-kafka-resp-err-no-error)
	(make-instance 'kafka-error :rd-kafka-resp-err err)))))