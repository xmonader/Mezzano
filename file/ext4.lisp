;;;; Copyright (c) 2018-2018 Bruno Cichon <ebrasca@librepanther.com>
;;;; This code is licensed under the MIT license.
;;;; This implementation can read from ext2, ext3 and ext4.

(defpackage :mezzano.ext4-file-system
  (:use :cl :mezzano.file-system :mezzano.file-system-cache :mezzano.disk-file-system :iterate)
  (:export)
  (:import-from #:sys.int
                #:explode))

(in-package :mezzano.ext4-file-system)

;; Compatible feature set flags.
(defconstant +compat-dir-prealloc+ #x1)
(defconstant +compat-imagic-inodes+ #x2)
(defconstant +compat-has-journal+ #x4)
(defconstant +compat-ext-attr+ #x8)
(defconstant +compat-resize-inode+ #x10)
(defconstant +compat-dir-index+ #x20)
(defconstant +compat-lazy-bg+ #x40)
(defconstant +compat-exclude-inode+ #x80)
(defconstant +compat-exclude-bitmap+ #x100)
(defconstant +compat-sparse-super2+ #x200)

;; Incompatible feature set.
(defconstant +incompat-compression+ #x1)
(defconstant +incompat-filetype+ #x2)
(defconstant +incompat-recover+ #x4)
(defconstant +incompat-journal-dev+ #x8)
(defconstant +incompat-meta-bg+ #x10)
(defconstant +incompat-extents+ #x40)
(defconstant +incompat-64bit+ #x80)
(defconstant +incompat-mmp+ #x100)
(defconstant +incompat-flex-bg+ #x200)
(defconstant +incompat-ea-inode+ #x400)
(defconstant +incompat-dirdata+ #x1000)
(defconstant +incompat-csum-seed+ #x2000)
(defconstant +incompat-largedir+ #x4000)
(defconstant +incompat-inline-data+ #x8000)
(defconstant +incompat-encrypt+ #x10000)

;; Readonly-compatible feature set.
(defconstant +ro-compat-sparse-super+ #x1)
(defconstant +ro-compat-large-file+ #x2)
(defconstant +ro-compat-btree-dir+ #x4)
(defconstant +ro-compat-huge-file+ #x8)
(defconstant +ro-compat-gdt-csum+ #x10)
(defconstant +ro-compat-dir-nlink+ #x20)
(defconstant +ro-compat-extra-isize+ #x40)
(defconstant +ro-compat-has-snapshot+ #x80)
(defconstant +ro-compat-quota+ #x100)
(defconstant +ro-compat-bigalloc+ #x200)
(defconstant +ro-compat-metadata-csum+ #x400)
(defconstant +ro-compat-replica+ #x800)
(defconstant +ro-compat-readonly+ #x1000)
(defconstant +ro-compat-project+ #x2000)

;; Inode flags
(defconstant +sync-flag+ #x8) ; All writes to the file must be synchronous
(defconstant +immutable-flag+ #x10) ; File is immutable
(defconstant +append-flag+ #x20) ; File can only be appended
(defconstant +noatime-flag+ #x80) ; Do not update access time
(defconstant +encrypt-flag+ #x800) ; Encrypted inode
(defconstant +hashed-indexes-flag+ #x1000) ; Directory has hashed indexes
(defconstant +imagic-flag+ #x2000) ; AFS magic directory
(defconstant +journal-data-flag+ #x4000) ; File data must always be written through the journal
(defconstant +notail-flag+ #x8000) ; File tail should not be merged (not used by ext4)
(defconstant +dirsync-flag+ #x10000) ; All directory entry data should be written synchronously
(defconstant +topdir-flag+ #x20000) ; Top of directory hierarchy
(defconstant +huge-file-flag+ #x40000) ; This is a huge file
(defconstant +extents-flag+ #x80000) ; Inode uses extents
(defconstant +ea-inode-flag+ #x200000) ; Inode stores a large extended attribute value in its data blocks
(defconstant +inline-data-flag+ #x10000000) ; Inode has inline data

;; Directory file types
(defconstant +unknown-type+ #x0)
(defconstant +regular-file-type+ #x1)
(defconstant +directory-type+ #x2)
(defconstant +character-device-type+ #x3)
(defconstant +block-device-type+ #x4)
(defconstant +fifo-type+ #x5)
(defconstant +socket-type+ #x6)
(defconstant +symbolic-link-type+ #x7)

(defstruct superblock
  (inodes-count nil :type (unsigned-byte 32))
  (blocks-count nil :type (unsigned-byte 64))
  (r-blocks-count nil :type (unsigned-byte 64))
  (free-blocks-count nil :type (unsigned-byte 64))
  (free-inodes-count nil :type (unsigned-byte 32))
  (first-data-block nil :type (unsigned-byte 32))
  (log-block-size nil :type (unsigned-byte 32))
  (log-cluster-size nil :type (unsigned-byte 32))
  (blocks-per-group nil :type (unsigned-byte 32))
  (clusters-per-group nil :type (unsigned-byte 32))
  (inodes-per-group nil :type (unsigned-byte 32))
  (mtime nil :type (unsigned-byte 32))
  (wtime nil :type (unsigned-byte 32))
  (mnt-count nil :type (unsigned-byte 32))
  (max-mnt-count nil :type (unsigned-byte 32))
  (magic nil :type (unsigned-byte 16))
  (state nil :type (unsigned-byte 16))
  (errors nil :type (unsigned-byte 16))
  (minor-rev-level nil :type (unsigned-byte 16))
  (lastcheck nil :type (unsigned-byte 32))
  (checkinterval nil :type (unsigned-byte 32))
  (creator-os nil :type (unsigned-byte 32))
  (rev-level nil :type (unsigned-byte 32))
  (def-resuid nil :type (unsigned-byte 16))
  (def-resgid nil :type (unsigned-byte 16))
  (first-ino nil :type (unsigned-byte 32))
  (inode-size nil :type (unsigned-byte 16))
  (block-group-nr nil :type (unsigned-byte 16))
  (feature-compat nil :type (unsigned-byte 32))
  (feature-incompat nil :type (unsigned-byte 32))
  (feature-ro-compat nil :type (unsigned-byte 32))
  (uuid nil :type (unsigned-byte 128))
  (volume-name nil :type string)
  (last-mounted nil :type string)
  (algorithm-bitmap nil :type (unsigned-byte 32))
  (prealloc-blocks nil :type (unsigned-byte 8))
  (prealloc-dir-blocks nil :type (unsigned-byte 8))
  (reserved-gdt-blocks nil :type (unsigned-byte 16))
  (journal-uuid nil :type (unsigned-byte 128))
  (journal-inum nil :type (unsigned-byte 32))
  (journal-dev nil :type (unsigned-byte 32))
  (last-orphan nil :type (unsigned-byte 32))
  (hash-seed nil)
  (def-hash-version nil :type (unsigned-byte 8))
  (jnl-backup-type nil :type (unsigned-byte 8))
  (desc-size nil :type (unsigned-byte 16))
  (default-mount-options nil :type (unsigned-byte 32))
  (first-meta-bg nil :type (unsigned-byte 32))
  (mkfs-time nil :type (unsigned-byte 32))
  (jnl-blocks nil)
  (min-extra-isize nil :type (unsigned-byte 16))
  (want-extra-isize nil :type (unsigned-byte 16))
  (flags nil :type (unsigned-byte 32))
  (raid-stride nil :type (unsigned-byte 16))
  (mmp-interval nil :type (unsigned-byte 16))
  (mmp-block nil :type (unsigned-byte 64))
  (raid-stripe-width nil :type (unsigned-byte 32))
  (log-groups-per-flex nil :type (unsigned-byte 8))
  (checksum-type nil :type (unsigned-byte 8))
  (reserved-pad nil :type (unsigned-byte 16))
  (kbytes-written nil :type (unsigned-byte 64))
  (snapshot-inum nil :type (unsigned-byte 32))
  (snapshot-id nil :type (unsigned-byte 32))
  (snapshot-r-blocks-count nil :type (unsigned-byte 64))
  (snapshot-list nil :type (unsigned-byte 32))
  (error-count nil :type (unsigned-byte 32))
  (first-error-time nil :type (unsigned-byte 32))
  (first-error-ino nil :type (unsigned-byte 32))
  (first-error-block nil :type (unsigned-byte 64))
  (first-error-func nil)
  (first-error-line nil :type (unsigned-byte 32))
  (last-error-time nil :type (unsigned-byte 32))
  (last-error-ino nil :type (unsigned-byte 32))
  (last-error-line nil :type (unsigned-byte 32))
  (last-error-block nil :type (unsigned-byte 64))
  (last-error-func nil)
  (mount-opts nil)
  (usr-quota-inum nil :type (unsigned-byte 32))
  (grp-quota-inum nil :type (unsigned-byte 32))
  (overhead-blocks nil :type (unsigned-byte 32))
  (backup-bgs nil)
  (encrypt-algos nil)
  (encrypt-pw-salt nil)
  (lpf-ino nil :type (unsigned-byte 32))
  (prj-quota-inum nil :type (unsigned-byte 32))
  (checksum-seed nil :type (unsigned-byte 32))
  (reserved nil)
  (checksum nil :type (unsigned-byte 32)))

(defun check-magic (magic)
  (unless (= magic #xEF53)
    (error "Bad magic : #x~x.
  Valid magic value is #xEF53." magic)))

(let* ((not-implemented (list +incompat-compression+
                              +incompat-journal-dev+
                              +incompat-meta-bg+
                              +incompat-mmp+
                              +incompat-ea-inode+
                              +incompat-dirdata+
                              +incompat-csum-seed+
                              +incompat-largedir+
                              +incompat-encrypt+))
       (sum (reduce #'logior not-implemented)))
  (defun check-feature-incompat (feature-incompat)
    (when (= +incompat-recover+ (logand +incompat-recover+ feature-incompat))
      (error "Filesystem needs recovery"))
    (unless (= +incompat-filetype+ (logand (+ +incompat-filetype+ sum) feature-incompat))
      (error "Required features not implemented : ~{#x~x ~}"
             (loop :for feature :in not-implemented
                   :unless (zerop (logand feature feature-incompat))
                   :collect (logand feature feature-incompat))))))

(defun read-superblock (disk)
  (let* ((superblock (read-sector disk 2 2))
         (magic (sys.int::ub16ref/le superblock 56))
         (feature-incompat (sys.int::ub32ref/le superblock 96)))
    (check-magic magic)
    (check-feature-incompat feature-incompat)
    (make-superblock :inodes-count (sys.int::ub32ref/le superblock 0)
                     :blocks-count (logior (ash (sys.int::ub32ref/le superblock 336) 64)
                                           (sys.int::ub32ref/le superblock 4))
                     :r-blocks-count (logior (ash (sys.int::ub32ref/le superblock 340) 64)
                                             (sys.int::ub32ref/le superblock 8))
                     :free-blocks-count (logior (ash (sys.int::ub32ref/le superblock 344) 64)
                                                (sys.int::ub32ref/le superblock 12))
                     :free-inodes-count (sys.int::ub32ref/le superblock 16)
                     :first-data-block (sys.int::ub32ref/le superblock 20)
                     :log-block-size (sys.int::ub32ref/le superblock 24)
                     :log-cluster-size (sys.int::ub32ref/le superblock 28)
                     :blocks-per-group (sys.int::ub32ref/le superblock 32)
                     :clusters-per-group (sys.int::ub32ref/le superblock 36)
                     :inodes-per-group (sys.int::ub32ref/le superblock 40)
                     :mtime (sys.int::ub32ref/le superblock 44)
                     :wtime (sys.int::ub32ref/le superblock 48)
                     :mnt-count (sys.int::ub16ref/le superblock 52)
                     :max-mnt-count (sys.int::ub16ref/le superblock 54)
                     :magic magic
                     :state (sys.int::ub16ref/le superblock 58)
                     :errors (sys.int::ub16ref/le superblock 60)
                     :minor-rev-level (sys.int::ub16ref/le superblock 62)
                     :lastcheck (sys.int::ub32ref/le superblock 64)
                     :checkinterval (sys.int::ub32ref/le superblock 68)
                     :creator-os (sys.int::ub32ref/le superblock 72)
                     :rev-level (sys.int::ub32ref/le superblock 76)
                     :def-resuid (sys.int::ub16ref/le superblock 80)
                     :def-resgid (sys.int::ub16ref/le superblock 82)
                     :first-ino (sys.int::ub32ref/le superblock 84)
                     :inode-size (sys.int::ub16ref/le superblock 88)
                     :block-group-nr (sys.int::ub16ref/le superblock 90)
                     :feature-compat (sys.int::ub32ref/le superblock 92)
                     :feature-incompat feature-incompat
                     :feature-ro-compat (sys.int::ub32ref/le superblock 100)
                     :uuid (logior (ash (sys.int::ub64ref/le superblock 112) 64)
                                   (sys.int::ub64ref/le superblock 104))
                     :volume-name (map 'string #'code-char (subseq superblock 120 136))
                     :last-mounted (map 'string #'code-char (subseq superblock 136 200))
                     :algorithm-bitmap (sys.int::ub32ref/le superblock 200)
                     :prealloc-blocks (aref superblock 204)
                     :prealloc-dir-blocks (aref superblock 205)
                     :reserved-gdt-blocks (sys.int::ub16ref/le superblock 206)
                     :journal-uuid (logior (ash (sys.int::ub64ref/le superblock 216) 64)
                                           (sys.int::ub64ref/le superblock 208))
                     :journal-inum (sys.int::ub32ref/le superblock 224)
                     :journal-dev (sys.int::ub32ref/le superblock 228)
                     :last-orphan (sys.int::ub32ref/le superblock 232)
                     :hash-seed (make-array '(4) :element-type '(unsigned-byte 32)
                                                 :initial-contents (list (sys.int::ub32ref/le superblock 236)
                                                                         (sys.int::ub32ref/le superblock 240)
                                                                         (sys.int::ub32ref/le superblock 244)
                                                                         (sys.int::ub32ref/le superblock 248)))
                     :def-hash-version (aref superblock 252)
                     :jnl-backup-type (aref superblock 253)
                     :desc-size (sys.int::ub16ref/le superblock 254)
                     :default-mount-options (sys.int::ub32ref/le superblock 256)
                     :first-meta-bg (sys.int::ub32ref/le superblock 260)
                     :mkfs-time (sys.int::ub32ref/le superblock 264)
                     :jnl-blocks (make-array '(17) :element-type '(unsigned-byte 32)
                                                   :initial-contents (loop :for i :from 268 :to 332 :by 4
                                                                           :collect (sys.int::ub32ref/le superblock i)))
                     :min-extra-isize (sys.int::ub16ref/le superblock 348)
                     :want-extra-isize (sys.int::ub16ref/le superblock 350)
                     :flags (sys.int::ub32ref/le superblock 352)
                     :raid-stride (sys.int::ub16ref/le superblock 356)
                     :mmp-interval (sys.int::ub16ref/le superblock 358)
                     :mmp-block (sys.int::ub64ref/le superblock 360)
                     :raid-stripe-width (sys.int::ub32ref/le superblock 368)
                     :log-groups-per-flex (aref superblock 372)
                     :checksum-type (aref superblock 373)
                     :reserved-pad (sys.int::ub16ref/le superblock 374)
                     :kbytes-written (sys.int::ub64ref/le superblock 376)
                     :snapshot-inum (sys.int::ub32ref/le superblock 384)
                     :snapshot-id (sys.int::ub32ref/le superblock 388)
                     :snapshot-r-blocks-count (sys.int::ub64ref/le superblock 392)
                     :snapshot-list (sys.int::ub32ref/le superblock 400)
                     :error-count (sys.int::ub32ref/le superblock 404)
                     :first-error-time (sys.int::ub32ref/le superblock 408)
                     :first-error-ino (sys.int::ub32ref/le superblock 412)
                     :first-error-block (sys.int::ub64ref/le superblock 416)
                     :first-error-func (make-array '(32) :element-type '(unsigned-byte 8)
                                                         :initial-contents (loop :for i :from 424 :to 455
                                                                                 :collect (aref superblock i)))
                     :first-error-line (sys.int::ub32ref/le superblock 456)
                     :last-error-time (sys.int::ub32ref/le superblock 460)
                     :last-error-ino (sys.int::ub32ref/le superblock 464)
                     :last-error-line (sys.int::ub32ref/le superblock 468)
                     :last-error-block (sys.int::ub64ref/le superblock 472)
                     :last-error-func (make-array '(32) :element-type '(unsigned-byte 8)
                                                        :initial-contents (loop :for i :from 480 :to 511
                                                                                :collect (aref superblock i)))
                     :mount-opts (make-array '(64) :element-type '(unsigned-byte 8)
                                                   :initial-contents (loop :for i :from 512 :to 575
                                                                           :collect (aref superblock i)))
                     :usr-quota-inum (sys.int::ub32ref/le superblock 576)
                     :grp-quota-inum (sys.int::ub32ref/le superblock 580)
                     :overhead-blocks (sys.int::ub32ref/le superblock 584)
                     :backup-bgs (make-array '(2) :element-type '(unsigned-byte 32)
                                                  :initial-contents (loop :for i :from 588 :to 592 :by 4
                                                                          :collect (sys.int::ub32ref/le superblock i)))
                     :encrypt-algos (make-array '(4) :element-type '(unsigned-byte 8)
                                                     :initial-contents (loop :for i :from 596 :to 599
                                                                             :collect (aref superblock i)))
                     :encrypt-pw-salt (make-array '(16) :element-type '(unsigned-byte 8)
                                                        :initial-contents (loop :for i :from 600 :to 615
                                                                                :collect (aref superblock i)))
                     :lpf-ino (sys.int::ub32ref/le superblock 616)
                     :prj-quota-inum (sys.int::ub32ref/le superblock 620)
                     :checksum-seed (sys.int::ub32ref/le superblock 624)
                     :reserved (make-array '(98) :element-type '(unsigned-byte 32)
                                                 :initial-contents (loop :for i :from 628 :to 1016 :by 4
                                                                         :collect (sys.int::ub32ref/le superblock i)))
                     :checksum (sys.int::ub32ref/le superblock 1020))))

(defun block-size (disk superblock)
  "Take disk and superblock, return block size in disk sectors"
  (/ (ash 1024 (superblock-log-block-size superblock))
     (mezzano.supervisor:disk-sector-size disk)))

(defun read-block (disk superblock block-n &optional (n-blocks 1))
  (let* ((block-size (block-size disk superblock))
         (sector-n (* block-size
                      (if (= (superblock-log-block-size superblock) 1)
                          (1+ block-n) block-n))))
    (read-sector disk sector-n (* n-blocks block-size))))

(defun block-size-in-bytes (disk superblock)
  "Take disk and superblock, return block size in bytes"
  (ash 1024 (superblock-log-block-size superblock)))

(defun block-group (inode-n superblock)
  "Return block group that an inode lives in"
  (floor (/ (1- inode-n) (superblock-inodes-per-group superblock))))

(defun index (inodee-n superblock)
  "Return index of an inode"
  (mod (1- inodee-n) (superblock-inodes-per-group superblock)))

(defun offset (inode-n superblock)
  "Return byte address within the inode table"
  (* (index inode-n superblock) (superblock-inode-size superblock)))

(defun n-block-groups (superblock)
  (let ((tmp (ceiling (/ (superblock-inodes-count superblock) (superblock-inodes-per-group superblock)))))
    (assert (= tmp (ceiling (/ (superblock-blocks-count superblock) (superblock-blocks-per-group superblock)))))
    (ceiling (/ (superblock-blocks-count superblock) (superblock-blocks-per-group superblock)))))

(defstruct block-group-descriptor
  (block-bitmap)
  (inode-bitmap)
  (inode-table)
  (free-blocks-count)
  (free-inodes-count)
  (used-dirs-count)
  (flags nil)
  (exclude-bitmap nil)
  (block-bitmap-csum nil)
  (inode-bitmap-csum nil)
  (itable-unused nil)
  (checksum nil)
  (reserved nil))

(defun read-block-group-descriptor (superblock block offset)
  (if (zerop (logand +incompat-64bit+ (superblock-feature-incompat superblock)))
      (make-block-group-descriptor :block-bitmap (sys.int::ub32ref/le block (+ 0 offset))
                                   :inode-bitmap (sys.int::ub32ref/le block (+ 4 offset))
                                   :inode-table (sys.int::ub32ref/le block (+ 8 offset))
                                   :free-blocks-count (sys.int::ub16ref/le block (+ 12 offset))
                                   :free-inodes-count (sys.int::ub16ref/le block (+ 14 offset))
                                   :used-dirs-count (sys.int::ub16ref/le block (+ 16 offset)))
      (make-block-group-descriptor :block-bitmap (logior (ash (sys.int::ub32ref/le block (+ 32 offset)) 32)
                                                         (sys.int::ub32ref/le block (+ 0 offset)))
                                   :inode-bitmap (logior (ash (sys.int::ub32ref/le block (+ 36 offset)) 32)
                                                         (sys.int::ub32ref/le block (+ 4 offset)))
                                   :inode-table (logior (ash (sys.int::ub32ref/le block (+ 40 offset)) 32)
                                                        (sys.int::ub32ref/le block (+ 8 offset)))
                                   :free-blocks-count (logior (ash (sys.int::ub16ref/le block (+ 44 offset)) 16)
                                                              (sys.int::ub16ref/le block (+ 12 offset)))
                                   :free-inodes-count (logior (ash (sys.int::ub16ref/le block (+ 46 offset)) 16)
                                                              (sys.int::ub16ref/le block (+ 14 offset)))
                                   :used-dirs-count (logior (ash (sys.int::ub16ref/le block (+ 48 offset)) 16)
                                                            (sys.int::ub16ref/le block (+ 16 offset)))
                                   :flags (sys.int::ub16ref/le block (+ 18 offset))
                                   :exclude-bitmap (logior (ash (sys.int::ub32ref/le block (+ 52 offset)) 32)
                                                           (sys.int::ub32ref/le block (+ 20 offset)))
                                   :block-bitmap-csum (logior (ash (sys.int::ub16ref/le block (+ 56 offset)) 16)
                                                              (sys.int::ub32ref/le block (+ 24 offset)))
                                   :inode-bitmap-csum (logior (ash (sys.int::ub16ref/le block (+ 58 offset)) 16)
                                                              (sys.int::ub32ref/le block (+ 26 offset)))
                                   :itable-unused (logior (ash (sys.int::ub16ref/le block (+ 50 offset)) 16)
                                                          (sys.int::ub16ref/le block (+ 28 offset)))
                                   :checksum (sys.int::ub16ref/le block (+ 30 offset))
                                   :reserved (sys.int::ub32ref/le block (+ 60 offset)))))

(defun read-block-group-descriptor-table (disk superblock)
  (make-array (list (n-block-groups superblock)) :initial-contents
              (iter (with block-group-size := (if (zerop (logand +incompat-64bit+
                                                                 (superblock-feature-incompat superblock)))
                                                  32 (superblock-desc-size superblock)))
                    (with n-octets := (* block-group-size (n-block-groups superblock)))
                    (with block := (read-block disk superblock 1
                                               (/ n-octets
                                                  (mezzano.supervisor:disk-sector-size disk)
                                                  (block-size disk superblock))))
                    (for offset :from 0 :below n-octets :by block-group-size)
                    (collecting (read-block-group-descriptor superblock block offset)))))

(defun read-block-bitmap (disk superblock bgds)
  (let ((n-blocks (if (zerop (logand +incompat-flex-bg+ (superblock-feature-incompat superblock)))
                      1 (expt 2 (superblock-log-groups-per-flex superblock)))))
    (read-block disk superblock (block-group-descriptor-block-bitmap bgds) n-blocks)))

(defun read-inode-bitmap (disk superblock bgds)
  (let ((n-blocks (if (zerop (logand +incompat-flex-bg+ (superblock-feature-incompat superblock)))
                      1 (expt 2 (superblock-log-groups-per-flex superblock)))))
    (read-block disk superblock (block-group-descriptor-inode-bitmap bgds) n-blocks)))

(defstruct inode
  (mode nil :type (unsigned-byte 16))
  (uid nil :type (unsigned-byte 16))
  (size nil :type (unsigned-byte 32))
  (atime nil :type (unsigned-byte 32))
  (ctime nil :type (unsigned-byte 32))
  (mtime nil :type (unsigned-byte 32))
  (dtime nil :type (unsigned-byte 32))
  (gid nil :type (unsigned-byte 16))
  (links-count nil :type (unsigned-byte 16))
  (blocks nil :type (unsigned-byte 32))
  (flags nil :type (unsigned-byte 32))
  (osd1 nil :type (unsigned-byte 32))
  (block nil)
  (generation nil :type (unsigned-byte 32))
  (file-acl nil :type (unsigned-byte 32))
  (dir-acl nil :type (unsigned-byte 32))
  (faddr nil :type (unsigned-byte 32))
  (osd2 nil :type (unsigned-byte 96)))

(defun read-inode (disk superblock bgdt inode-n)
  (let* ((bgds (aref bgdt (block-group inode-n superblock)))
         (n-blocks (if (zerop (logand +incompat-flex-bg+ (superblock-feature-incompat superblock)))
                       1 (expt 2 (superblock-log-groups-per-flex superblock))))
         (block (read-block disk
                            superblock
                            (+ (block-group-descriptor-inode-table bgds)
                               (floor (/ (offset inode-n superblock)
                                         (block-size-in-bytes disk superblock))))
                            n-blocks))
         (offset (mod (offset inode-n superblock) (block-size-in-bytes disk superblock))))
    (make-inode :mode (sys.int::ub16ref/le block (+ 0 offset))
                :uid (sys.int::ub16ref/le block (+ 2 offset))
                :size (sys.int::ub32ref/le block (+ 4 offset))
                :atime (sys.int::ub32ref/le block (+ 8 offset))
                :ctime (sys.int::ub32ref/le block (+ 12 offset))
                :mtime (sys.int::ub32ref/le block (+ 16 offset))
                :dtime (sys.int::ub32ref/le block (+ 20 offset))
                :gid (sys.int::ub16ref/le block (+ 24 offset))
                :links-count (sys.int::ub16ref/le block (+ 26 offset))
                :blocks (sys.int::ub32ref/le block (+ 28 offset))
                :flags (sys.int::ub32ref/le block (+ 32 offset))
                :osd1 (sys.int::ub32ref/le block (+ 36 offset))
                :block (subseq block (+ 40 offset) (+ 100 offset))
                :generation (sys.int::ub32ref/le block (+ 100 offset))
                :file-acl (sys.int::ub32ref/le block (+ 104 offset))
                :dir-acl (sys.int::ub32ref/le block (+ 108 offset))
                :faddr (sys.int::ub32ref/le block (+ 112 offset))
                :osd2 (logior (ash (sys.int::ub32ref/le block (+ 124 offset)) 64)
                              (sys.int::ub64ref/le block (+ 116 offset))))))

(defstruct linked-directory-entry
  (inode nil :type (unsigned-byte 32))
  (rec-len nil :type (unsigned-byte 16))
  (name-len nil :type (unsigned-byte 8))
  (file-type nil :type (unsigned-byte 8))
  (name nil :type string))

(defun read-linked-directory-entry (block offset)
  (let* ((name-len (aref block (+ 6 offset))))
    (make-linked-directory-entry :inode (sys.int::ub32ref/le block (+ 0 offset))
                                 :rec-len (sys.int::ub16ref/le block (+ 4 offset))
                                 :name-len name-len
                                 :file-type (aref block (+ 7 offset))
                                 :name (map 'string #'code-char
                                            (subseq block
                                                    (+ 8 offset)
                                                    (+ 8 offset name-len))))))

(defstruct extent-header
  (magic nil :type (unsigned-byte 16))
  (entries nil :type (unsigned-byte 16))
  (max nil :type (unsigned-byte 16))
  (depth nil :type (unsigned-byte 16)))

(defun read-extent-header (inode-block)
  (let ((magic (sys.int::ub16ref/le inode-block 0)))
    (assert (= #xF30A magic))
    (make-extent-header :magic magic
                        :entries (sys.int::ub16ref/le inode-block 2)
                        :max (sys.int::ub16ref/le inode-block 4)
                        :depth (sys.int::ub16ref/le inode-block 6))))

(defstruct extent
  (n-block nil :type (unsigned-byte 32))
  (length nil :type (unsigned-byte 16))
  (start-block nil :type (unsigned-byte 48)))

(defun read-extent (inode-block offset)
  (let ((length (sys.int::ub16ref/le inode-block (+ 4 offset))))
    (when (> length 32768)
      (error "Uninitialized extent not suported"))
    (make-extent :n-block (sys.int::ub16ref/le inode-block offset)
                 :length length
                 :start-block (logior (ash (sys.int::ub16ref/le inode-block (+ 6 offset)) 32)
                                      (sys.int::ub32ref/le inode-block (+ 8 offset))))))

(defun follow-pointer (disk superblock block-n fn n-indirection)
  (if (zerop n-indirection)
      (funcall fn (read-block disk superblock block-n))
      (iter (with i-block := (read-block disk superblock block-n))
            (for offset :from 0 :below (block-size-in-bytes disk superblock) :by 4)
            (for block-n := (sys.int::ub32ref/le i-block offset))
            (unless (and (zerop block-n))
              (follow-pointer disk superblock block-n fn (1- n-indirection))))))

(defun do-file (fn disk superblock bgdt inode-n)
  (let* ((inode (read-inode disk superblock bgdt inode-n))
         (inode-block (inode-block inode))
         (inode-flags (inode-flags inode)))
    (cond ((= +extents-flag+ (logand +extents-flag+ inode-flags))
           ;; TODO Add support for extent-header-depth not equal to 0
           (let ((extent-header (read-extent-header inode-block)))
             (unless (zerop (extent-header-depth extent-header))
               (error "Not 0 depth extents nodes not implemented"))
             (iter (for offset :from 12 :by 12)
                   (for extent := (read-extent inode-block offset))
                   (repeat (extent-header-entries extent-header))
                   (iter (for block-n :from (extent-start-block extent))
                         (repeat (extent-length extent))
                         (funcall fn (read-block disk superblock block-n))))))
          ((= +inline-data-flag+ (logand +inline-data-flag+ inode-flags))
           (funcall fn inode-block))
          (t
           (iter (for offset :from 0 :below 48 :by 4)
                 (for block-n := (sys.int::ub32ref/le inode-block offset))
                 (never (zerop block-n))
                 (follow-pointer disk superblock block-n fn 0))
           (iter (for offset :from 48 :below 60 :by 4)
                 (for indirection :from 1)
                 (for block-n := (sys.int::ub32ref/le inode-block offset))
                 (never (zerop block-n))
                 (follow-pointer disk superblock block-n fn indirection))))))

(defun read-file (disk superblock bgdt inode-n)
  (let ((blocks))
    (do-file #'(lambda (block)
                 (push block blocks))
      disk superblock bgdt inode-n)
    (iter (with block-size := (block-size-in-bytes disk superblock))
          (with result := (make-array (list (* block-size (length blocks))) :element-type '(unsigned-byte 8)))
          (for block :in (nreverse blocks))
          (for offset :from 0 :by block-size)
          (replace result block :start1 offset)
          (finally (return result)))))

(defmacro do-files ((arg var) disk superblock bgdt inode-n finally &body body)
  `(unless (do-file (lambda (,arg)
                      (do ((,var 0 (+ ,var (sys.int::ub16ref/le ,arg (+ 4 ,var)))))
                          ((= ,var (block-size-in-bytes disk superblock)) nil)
                        ,@body))
             ,disk ,superblock ,bgdt ,inode-n)
     ,finally))

;;; Host integration

(defclass ext-host ()
  ((%name :initarg :name
          :reader host-name)
   (%lock :initarg :lock
          :reader ext-host-lock)
   (partition :initarg :partition
              :reader partition)
   (superblock :initarg :superblock
               :reader superblock)
   (bgdt :initarg :bgdt
         :reader bgdt))
  (:default-initargs :lock (mezzano.supervisor:make-mutex "Local File Host lock")))

(defmethod host-default-device ((host ext-host))
  nil)

(defun parse-simple-file-path (host namestring)
  (let ((start 0)
        (end (length namestring))
        (directory '())
        (name nil)
        (type nil))
    (when (eql start end)
      (return-from parse-simple-file-path (make-pathname :host host)))
    (cond ((eql (char namestring start) #\>)
           (push :absolute directory)
           (incf start))
          (t (push :relative directory)))
    ;; Last element is the name.
    (do* ((x (explode #\> namestring start end) (cdr x)))
         ((null (cdr x))
          (let* ((name-element (car x))
                 (end (length name-element)))
            (unless (zerop (length name-element))
              ;; Find the last dot.
              (let ((dot-position (position #\. name-element :from-end t)))
                (cond ((and dot-position (not (zerop dot-position)))
                       (setf type (subseq name-element (1+ dot-position) end))
                       (setf name (subseq name-element 0 dot-position)))
                      (t (setf name (subseq name-element 0 end))))))))
      (let ((dir (car x)))
        (cond ((or (string= "" dir)
                   (string= "." dir)))
              ((string= ".." dir)
               (push :up directory))
              ((string= "*" dir)
               (push :wild directory))
              ((string= "**" dir)
               (push :wild-inferiors directory))
              (t (push dir directory)))))
    (when (string= name "*") (setf name :wild))
    (when (string= type "*") (setf type :wild))
    (make-pathname :host host
                   :directory (nreverse directory)
                   :name name
                   :type type
                   :version :newest)))

(defmethod parse-namestring-using-host ((host ext-host) namestring junk-allowed)
  (assert (not junk-allowed) (junk-allowed) "Junk-allowed not implemented yet")
  (parse-simple-file-path host namestring))

(defmethod namestring-using-host ((host ext-host) pathname)
  (when (pathname-device pathname)
    (error 'no-namestring-error
           :pathname pathname
           :format-control "Pathname has a device component"))
  (let ((dir (pathname-directory pathname))
        (name (pathname-name pathname))
        (type (pathname-type pathname)))
    (with-output-to-string (s)
      (when (eql (first dir) :absolute)
        (write-char #\> s))
      (dolist (sub-dir (rest dir))
        (cond
          ((stringp sub-dir) (write-string sub-dir s))
          ((eql sub-dir :up) (write-string ".." s))
          ((eql sub-dir :wild) (write-char #\* s))
          ((eql sub-dir :wild-inferiors) (write-string "**" s))
          (t (error 'no-namestring-error
                    :pathname pathname
                    :format-control "Invalid directory component ~S."
                    :format-arguments (list sub-dir))))
        (write-char #\> s))
      (cond ((eql name :wild)
             (write-char #\* s))
            (name
             (write-string name s)))
      (when type
        (write-char #\. s)
        (if (eql type :wild)
            (write-char #\* s)
            (write-string type s)))
      s)))

(defun file-name (pathname)
  "Take pathname and return file name."
  (unless (or (eql :wild (pathname-name pathname))
              (eql :wild (pathname-type pathname)))
    (if (pathname-type pathname)
        (concatenate 'string (pathname-name pathname) "." (pathname-type pathname))
        (pathname-name pathname))))

(defun find-file (host pathname)
  (loop :with disk := (partition host)
        :with superblock := (superblock host)
        :with bgdt := (bgdt host)
        :with inode-n := 2
        :with file-name := (file-name pathname)
        :for directory :in (rest (pathname-directory pathname))
        :do (block do-files
              (do-files (block offset) disk superblock bgdt inode-n
                (error 'simple-file-error
                       :pathname pathname
                       :format-control "Directory ~A not found. ~S"
                       :format-arguments (list directory pathname))
                (when (string= directory (linked-directory-entry-name (read-linked-directory-entry block offset)))
                  (setf inode-n (linked-directory-entry-inode (read-linked-directory-entry block offset)))
                  (return-from do-files t))))
        :finally
        (if (null file-name)
            (return inode-n)
            (block do-files
              (do-files (block offset) disk superblock bgdt inode-n nil
                (when (string= file-name (linked-directory-entry-name (read-linked-directory-entry block offset)))
                  (return-from find-file (linked-directory-entry-inode (read-linked-directory-entry block offset)))))))))

(defclass ext-file-stream (sys.gray:fundamental-binary-input-stream
                           sys.gray:fundamental-binary-output-stream
                           file-cache-stream
                           file-stream)
  ((pathname :initarg :pathname :reader file-stream-pathname)
   (host :initarg :host :reader host)
   (file-inode :initarg :file-inode :accessor file-inode)
   (abort-action :initarg :abort-action :accessor abort-action)))

(defclass ext-file-character-stream (sys.gray:fundamental-character-input-stream
                                     sys.gray:fundamental-character-output-stream
                                     file-cache-character-stream
                                     ext-file-stream
                                     sys.gray:unread-char-mixin)
  ())

(defmacro with-ext-host-locked ((host) &body body)
  `(mezzano.supervisor:with-mutex ((ext-host-lock ,host))
     ,@body))

;; WIP
(defmethod open-using-host ((host ext-host) pathname
                            &key direction element-type if-exists if-does-not-exist external-format)
  (with-ext-host-locked (host)
    (let ((file-inode nil)
          (buffer nil)
          (file-position 0)
          (file-length 0)
          (created-file nil)
          (abort-action nil))
      (let ((inode-n (find-file host pathname)))
        (if inode-n
            (let ((file-inode (read-inode (partition host) (superblock host) (bgdt host) inode-n)))
              (setf file-inode file-inode
                    buffer (read-file (partition host) (superblock host) (bgdt host) inode-n)
                    file-length (inode-size file-inode)))
            (ecase if-does-not-exist
              (:error (error 'simple-file-error
                             :pathname pathname
                             :format-control "File ~A does not exist. ~S"
                             :format-arguments (list pathname (file-name pathname))))
              (:create (setf created-file t
                             abort-action :delete)
               (error ":create not implemented")))))
      (when (and (not created-file) (member direction '(:output :io)))
        (error ":output :io not implemented"))
      (let ((stream (cond ((or (eql element-type :default)
                               (subtypep element-type 'character))
                           (assert (member external-format '(:default :utf-8))
                                   (external-format))
                           (make-instance 'ext-file-character-stream
                                          :pathname pathname
                                          :host host
                                          :direction direction
                                          :file-inode file-inode
                                          :buffer buffer
                                          :position file-position
                                          :length file-length
                                          :abort-action abort-action))
                          ((and (subtypep element-type '(unsigned-byte 8))
                                (subtypep '(unsigned-byte 8) element-type))
                           (assert (eql external-format :default) (external-format))
                           (make-instance 'ext-file-stream
                                          :pathname pathname
                                          :host host
                                          :direction direction
                                          :file-inode file-inode
                                          :buffer buffer
                                          :position file-position
                                          :length file-length
                                          :abort-action abort-action))
                          (t (error "Unsupported element-type ~S." element-type)))))
        stream))))

(defmethod probe-using-host ((host ext-host) pathname)
  (multiple-value-bind (inode-n) (find-file host pathname)
    (if inode-n t nil)))

;; WIP
(defmethod directory-using-host ((host ext-host) pathname &key)
  (let ((inode-n (find-file host pathname))
        (disk (partition host))
        (superblock (superblock host))
        (bgdt (bgdt host))
        (stack '())
        (path (directory-namestring pathname)))
    (do-files (block offset) disk superblock bgdt inode-n t
      (let* ((file (read-linked-directory-entry block offset))
             (type (linked-directory-entry-file-type file)))
        (unless (= +unknown-type+ type)
          (push (parse-simple-file-path host
                                        (format nil
                                                (if (= +directory-type+ type)
                                                    "~a~a>"
                                                    "~a~a")
                                                path
                                                (linked-directory-entry-name file)))
                stack))))
    (return-from directory-using-host stack)))

;; (defmethod ensure-directories-exist-using-host ((host ext-host) pathname &key verbose))

;; (defmethod rename-file-using-host ((host ext-host) source dest))

;; (defmethod file-write-date-using-host ((host ext-host) path))

;; (defmethod delete-file-using-host ((host ext-host) path &key))

(defmethod expunge-directory-using-host ((host ext-host) path &key)
  (declare (ignore host path))
  t)

(defmethod stream-truename ((stream ext-file-stream))
  (file-stream-pathname stream))

(defmethod close ((stream ext-file-stream) &key abort)
  t)
