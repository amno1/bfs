;;; bfs.el --- Browse File System -*- lexical-binding: t; -*-

;;; Packages

(require 's)
(require 'f)
(require 'dash)

;;; Movements

(defvar bfs-visited-backward nil
  "List of child files that have been visited.  Child files are
added uniquely to `bfs-visited-backward' only when we use
`bfs-backward' command.  This allow `bfs-forward' to be smart.")

(defun bfs-get-visited-backward (child)
  "Return the element of `bfs-visited-backward' which directory name match CHILD.
Return nil if there is no matches."
  (--first (f-equal-p child (f-dirname it)) bfs-visited-backward))

(defun bfs-update-visited-backward (child)
  "Add CHILD to `bfs-visited-backward' conditionally."
  (unless (or (and (f-directory-p child)
                   (not (file-accessible-directory-p child)))
              (not (bfs-file-readable-p child)))
    (setq bfs-visited-backward
          (cons child
                (--remove (f-equal-p (f-dirname child) (f-dirname it))
                          bfs-visited-backward)))))

(defun bfs-previous ()
  "Preview previous file."
  (interactive)
  (unless (bobp) (forward-line -1))
  (bfs-preview (bfs-child)))

(defun bfs-next ()
  "Preview next file."
  (interactive)
  (unless (= (line-number-at-pos) (1- (line-number-at-pos (point-max))))
    (forward-line))
  (bfs-preview (bfs-child)))

(defun bfs-backward ()
  "Update `bfs' environment making parent entry the child entry.
In other words, go up by one node in the file system tree."
  (interactive)
  (unless (f-root-p default-directory)
    (bfs-update-visited-backward (bfs-child))
    (bfs-update default-directory)))

(defun bfs-forward ()
  "Update `bfs' environment making child entry the parent entry.
In other words, go down by one node in the file system tree.

If child entry (is not a directory) and is a readable file, leave `bfs'
environment and visit that file."
  (interactive)
  (let* ((child (bfs-child)))
    (cond ((and (f-directory-p child)
                (not (file-accessible-directory-p child)))
           (message "Permission denied: %s" child))
          ((f-directory-p child)
           (let ((visited (bfs-get-visited-backward child))
                 (readable (bfs-first-readable-file child)))
             (cond (visited (bfs-update visited))
                   ((and readable (s-blank-p readable))
                    (bfs-clean)
                    (delete-other-windows)
                    (dired child))
                   (readable (bfs-update (f-join child readable)))
                   (t (message
                       (s-concat "Files are not readable, or are too large, "
                                 "or have discarded extensions, in directory: %s")
                       child)))))
          (t
           (let (child-buffer)
             (condition-case err
                 (setq child-buffer (find-file-noselect child))
               (file-error (message "%s" (error-message-string err))))
             (when child-buffer
               (bfs-clean)
               (delete-other-windows)
               (find-file child)))))))

;;; Scrolling

(defun bfs-half-window-height ()
  "Compute half window height."
  (/ (window-body-height) 2))

(defun bfs-scroll-preview-down-half-window ()
  "Scroll preview window down of half window height."
  (interactive)
  (scroll-other-window-down (bfs-half-window-height)))

(defun bfs-scroll-preview-up-half-window ()
  "Scroll preview window up of half window height."
  (interactive)
  (scroll-other-window (bfs-half-window-height)))

(defun bfs-scroll-down-half-window ()
  "Scroll child window down of half window height."
  (interactive)
  (scroll-down (bfs-half-window-height))
  (bfs-preview (bfs-child)))

(defun bfs-scroll-up-half-window ()
  "Scroll child window up of half window height."
  (interactive)
  (scroll-up (bfs-half-window-height))
  (if (eobp) (bfs-previous)
    (bfs-preview (bfs-child))))

(defun bfs-beginning-of-buffer ()
  "Move to beginning of buffer."
  (interactive)
  (call-interactively 'beginning-of-buffer)
  (bfs-preview (bfs-child)))

(defun bfs-end-of-buffer ()
  "Move to beginning of buffer."
  (interactive)
  (call-interactively 'end-of-buffer)
  (if (eobp) (bfs-previous)
    (bfs-preview (bfs-child))))

;;; Utilities

(defun bfs-child-entry ()
  "Return the current child entry."
  (with-current-buffer bfs-child-buffer-name
    (buffer-substring-no-properties (point-at-bol) (point-at-eol))))

(defun bfs-parent-entry ()
  "Return the current parent entry."
  (with-current-buffer bfs-child-buffer-name
    (f-filename default-directory)))

(defun bfs-file-readable-p (file)
  "Return t if FILE is a readable satisfaying:
- its extension doesn't belong to `bfs-ignored-extensions',
- and its size is less than `bfs-max-size'.

See `file-readable-p'."
  (and (file-readable-p file)
       (not (member (file-name-extension file)
                    bfs-ignored-extensions))
       (< (file-attribute-size (file-attributes file))
          bfs-max-size)))

(defun bfs-first-readable-file (dir)
  "Return the first file/directory of DIR directory satisfaying
`bfs-file-readable-p'.

Return nil if none are found.
Return an empty string if DIR directory is empty."
  (--first (bfs-file-readable-p (f-join dir it))
           (-> (s-join " " (list bfs-ls-cli dir))
               (shell-command-to-string)
               (s-chomp)
               (s-lines))))

(defun bfs-child-entry-initial (buffer)
  "Return the file name of BUFFER.
Return nil if we can't determine a \"suitable\" file name for BUFFER.

See `bfs-first-readable-file'."
  (with-current-buffer buffer
    (cond ((buffer-file-name) (f-filename (buffer-file-name)))
          ((and (dired-file-name-at-point)
                (bfs-file-readable-p (dired-file-name-at-point)))
           (f-filename (dired-file-name-at-point)))
          (t (bfs-first-readable-file default-directory)))))

(defun bfs-goto-entry (entry)
  "Move the cursor to the line ENTRY."
  (goto-char (point-min))
  (search-forward-regexp (s-concat "^" entry) nil t)
  (beginning-of-line))

;;; Create, display and update buffers

(defvar bfs-kill-buffer-eagerly nil
  "When t, kill opened buffer upon a new child entry file is previewed.
When nil, opened buffers are killed when leaving `bfs' environment.")

(defvar bfs-ignored-extensions '("mkv" "iso" "mp4" "jpg" "png")
  "Don't preview files with those extensions.")

(defvar bfs-max-size large-file-warning-threshold
  "Don't preview files larger than this size.")

(defvar bfs-ls-cli "ls -Ap --group-directories-first"
  "The ls command line with the flags used.

The -p flag of ls append a / to the listed directories.
We use it to fontify the directories in `bfs-child-buffer-name'
and `bfs-parent-buffer-name'.  See `bfs-re-dir' and
`bfs-font-lock-keywords'.")

(defvar bfs-parent-buffer-name "*bfs-parent*"
  "Parent buffer name.")

(defvar bfs-child-buffer-name "*bfs-child*"
  "Child buffer name.")

(defvar bfs-parent-window-parameters
  '(display-buffer-in-side-window
    (side . left)
    (window-width . 0.2)
    (window-parameters . ((no-other-window . t)))))

(defvar bfs-child-window-parameters '(display-buffer-same-window))

(defvar bfs-preview-window-parameters
  '(display-buffer-in-direction
    (direction . right)
    (window-width . 0.6)))

(defvar bfs-frame nil
  "Frame where the `bfs' environment has been started.
Used internally.")

(defvar bfs-windows nil
  "Plist that store `bfs' windows information.
Used internally.
Properties of this plist are: :parent, :child, :preview")

(defvar bfs-is-active nil
  "t means that `bfs' environment has been turned on
in the frame `bfs-frame'.
Used internally.")

(defun bfs-parent-buffer (parent)
  "Produce `bfs-parent-buffer-name' buffer with the listing
of the directory containing PARENT directory."
  (with-current-buffer (get-buffer-create bfs-parent-buffer-name)
    (read-only-mode -1)
    (erase-buffer)
    (cond ((f-root-p parent) (insert "/") (bfs-goto-entry "/"))
          (t (-> (s-join " " (list bfs-ls-cli (f-parent parent)))
                 shell-command-to-string
                 insert)
             (bfs-goto-entry (f-filename parent))))
    (bfs-mode parent)))

(defun bfs-child-buffer (parent child-entry)
  "Produce `bfs-child-buffer-name' buffer with the listing
of the directory PARENT and the cursor at CHILD entry."
  (with-current-buffer (get-buffer-create bfs-child-buffer-name)
    (read-only-mode -1)
    (erase-buffer)
    (-> (s-join " " (list bfs-ls-cli parent))
        shell-command-to-string
        insert)
    (bfs-goto-entry child-entry)
    (bfs-mode parent)))

(defun bfs-preview (child &optional first-time)
  "Preview file CHILD on the right window.
When FIRST-TIME is non-nil, set the window layout."
  (let (preview-window)
    (cond ((bfs-preview-matches-child-p) nil) ; do nothing
          ((member (file-name-extension child)
                   bfs-ignored-extensions)
           nil) ; do nothing
          ((> (file-attribute-size (file-attributes child))
              bfs-max-size)
           nil) ; do nothing
          (first-time
           (setq preview-window
                 (display-buffer (find-file-noselect child)
                                 bfs-preview-window-parameters)))
          (t (setq preview-window
                   (display-buffer (find-file-noselect child) t))))
    (when preview-window
      (when (and bfs-kill-buffer-eagerly bfs-visited-file-buffers)
        (kill-buffer (pop bfs-visited-file-buffers)))
      (unless (-contains-p
               (-union bfs-buffer-list-before bfs-visited-file-buffers)
               (window-buffer preview-window))
        (push (window-buffer preview-window) bfs-visited-file-buffers)))
    preview-window))

(defun bfs-preview-update ()
  "Update the preview window with the current child entry file.

Intended to be added to `isearch-update-post-hook' and
`isearch-mode-end-hook'.  This allows to preview the file the
cursor has moved to using \"isearch\" commands in
`bfs-child-buffer-name' buffer."
  (bfs-preview (bfs-child)))

(defun bfs-child-is-valid-p (child)
  "Return t if CHILD file can be previewed in `bfs' environment."
  (not (cond ((not (f-exists-p child))
              (message "File doesn't exist: %s" child))
             ((and (f-directory-p child)
                   (not (file-accessible-directory-p child)))
              (message "Permission denied: %s" child))
             ((not (bfs-file-readable-p child))
              (message (s-concat "File is not readable, or is too large, "
                                 "or have discarded extensions: %s")
                       child)))))

(defun bfs-update (child)
  "Update `bfs' environment according to CHILD file."
  (when (bfs-child-is-valid-p child)
    (let ((inhibit-message t) parent child-entry)
      (if (f-root-p child)
          (progn (setq parent "/")
                 (setq child-entry (bfs-first-readable-file "/")))
        (setq parent (f-dirname child))
        (setq child-entry (f-filename child)))
      (bfs-parent-buffer parent)
      (bfs-child-buffer parent child-entry)
      (bfs-preview (f-join parent child-entry)))))

(defun bfs-display (child)
  "Display `bfs' buffers in a 3 panes layout for PARENT and
CHILD-ENTRY arguments.
Intended to be called only once in `bfs'."
  (when (window-parameter (selected-window) 'window-side)
    (other-window 1))
  (delete-other-windows)
  (bfs-parent-buffer (f-dirname child))
  (bfs-child-buffer (f-dirname child) (f-filename child))
  (setq bfs-frame (selected-frame))
  (setq bfs-windows
        (plist-put bfs-windows
                   :parent (display-buffer
                            bfs-parent-buffer-name
                            bfs-parent-window-parameters)))
  (setq bfs-windows
        (plist-put bfs-windows
                   :child (display-buffer
                           bfs-child-buffer-name
                           bfs-child-window-parameters)))
  (setq bfs-windows
        (plist-put bfs-windows
                   :preview (bfs-preview child t))))

;;; Find a file

(defun bfs-find-file (filename)
  "Find a file with your completion framework and update `bfs' environment."
  (interactive
   (list (read-file-name "Find file:" nil default-directory t)))
  (bfs-update filename))

;;; Leave bfs

(defun bfs-child ()
  "Return file path corresponding to the current child entry.
If `bfs-child-buffer-name' isn't lived return nil."
  (when (buffer-live-p (get-buffer bfs-child-buffer-name))
    (with-current-buffer bfs-child-buffer-name
      (f-join default-directory (bfs-child-entry)))))

(defun bfs-preview-buffer-name ()
  "Return the buffer-name of the preview window if lived.
Return nil if preview window isn't lived.

See `bfs-windows'."
  (when (window-live-p (plist-get bfs-windows :preview))
    (buffer-name (window-buffer (plist-get bfs-windows :preview)))))

(defun bfs-preview-matches-child-p ()
  "Return t if buffer of preview window matches the child entry."
  (when-let* ((child (bfs-child))
              (preview-buffer-name (bfs-preview-buffer-name))
              (preview-file-path
               (with-current-buffer preview-buffer-name
                 (if (equal major-mode 'dired-mode)
                     default-directory
                   (buffer-file-name)))))
    (f-equal-p preview-file-path child)))

(defun bfs-valid-layout-p ()
  "Return t if the window layout in `bfs-frame' frame
corresponds to the `bfs' environment layout."
  (let ((parent-win (plist-get bfs-windows :parent))
        (child-win (plist-get bfs-windows :child))
        (preview-win (plist-get bfs-windows :preview))
        (normal-window-list
         ;; we want the bfs layout to be valid when either `transient' or
         ;; `hydra' (when using lv-message, see `hydra-hint-display-type'
         ;; and `lv')  package pops up a window.  So we don't take those
         ;; popped up windows into account to validate the layout.
         (--remove (member (buffer-name (window-buffer it))
                           '(" *transient*" " *LV*"))
                   (window-list))))
    (when (-all-p 'window-live-p `(,parent-win ,child-win ,preview-win))
      (and (equal (length normal-window-list) 3)
           (string= (buffer-name (window-buffer (window-in-direction 'right parent-win)))
                    bfs-child-buffer-name)
           (string= (buffer-name (window-buffer (window-in-direction 'right preview-win t nil t)))
                    bfs-parent-buffer-name)))))

(defvar bfs-do-not-check-after
  '(bfs bfs-backward bfs-forward bfs-find-file)
  "List of commands after which we don't want to check the validity of
`bfs' environment.")

(defun bfs-check-environment ()
  "Leave `bfs' environment if it isn't valid.

We use `bfs-check-environment' in `window-configuration-change-hook'.
This ensure not to end in an inconsistent (unwanted) emacs state
after running any command that invalidate `bfs' environment.

For instance, your `bfs' environment stops to be valid:
1. when you switch to a buffer not attached to a file,
2. when you modify the layout deleting or rotating windows,
3. when you run any command that makes the previewed buffer
   no longer match the child entry.

See `bfs-valid-layout-p' and `bfs-preview-matches-child-p'."
  (cond
   ((or (window-minibuffer-p)
        (not (eq (selected-frame) bfs-frame))
        (memq last-command bfs-do-not-check-after))
    nil) ;; do nothing
   ((or (not (bfs-valid-layout-p))
        (not (bfs-preview-matches-child-p)))
    (bfs-clean)
    (when (window-parameter (selected-window) 'window-side)
      (other-window 1))
    (delete-other-windows))
   (t nil)))

(defun bfs-clean-if-frame-deleted (_frame)
  "Clean `bfs' environment if the frame that was running it has been deleted.
Intended to be added to `after-delete-frame-functions'."
  (unless (frame-live-p bfs-frame)
    (bfs-clean)))

(defvar bfs-visited-file-buffers nil
  "List of live buffers visited with `bfs-preview' function
during a `bfs' session.
Used internally.")

(defvar bfs-buffer-list-before nil
  "List of all live buffers when entering in the `bfs' environment.
Used internally.")

(defun bfs-kill-visited-file-buffers ()
  "Kill the buffers used to preview files with `bfs-preview'.
This doesn't kill buffers in `bfs-buffer-list-before' that was lived
before entering in the `bfs' environment."
  (-each (-difference bfs-visited-file-buffers bfs-buffer-list-before)
    'kill-buffer)
  (setq bfs-visited-file-buffers nil)
  (setq bfs-buffer-list-before nil))

(defun bfs-clean ()
  "Leave `bfs' environment and clean emacs state."
  (unless (window-minibuffer-p)
    (setq bfs-is-active nil)
    (remove-function after-delete-frame-functions 'bfs-clean-if-frame-deleted)
    (remove-hook 'window-configuration-change-hook 'bfs-check-environment)
    (remove-hook 'isearch-mode-end-hook 'bfs-preview-update)
    (remove-hook 'isearch-update-post-hook 'bfs-preview-update)
    (kill-new (f-join default-directory (bfs-child-entry)))
    (setq bfs-visited-backward nil)
    (setq bfs-frame nil)
    (setq bfs-windows nil)
    (bfs-kill-visited-file-buffers)
    (when (get-buffer bfs-parent-buffer-name)
      (kill-buffer bfs-parent-buffer-name))
    (when (get-buffer bfs-child-buffer-name)
      (kill-buffer bfs-child-buffer-name))))

(defun bfs-quit ()
  "Leave `bfs-mode' and restore previous window configuration."
  (interactive)
  (bfs-clean)
  (jump-to-register :bfs))

;;; bfs-mode

(defgroup bfs nil "Browsing File System." :group 'files)

(defface bfs-directory
  '((t (:foreground "#458b74")))
  "Face used for subdirectories."
  :group 'bfs)

(defvar bfs-directory-face 'bfs-directory
  "Face name used for subdirectories.")

(defvar bfs-re-dir ".*/$")

(defvar bfs-font-lock-keywords
  `((,bfs-re-dir . bfs-directory-face)))

(defvar bfs-hl-line-background "#394851"
  "Background color of `hl-line' in `bfs-mode'.")

(defvar bfs-hl-line-foreground "#cfcdba"
  "forground color of `hl-line' in `bfs-mode'.")

(defvar bfs-hl-line-is-bold t
  "Whether `hl-line' must be 'bold or not in `bfs-mode'.")

(defvar bfs-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") 'bfs-quit)
    map)
  "Keymap for `bfs-mode'.")

(defvar bfs-child-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map bfs-mode-map)

    (define-key map (kbd "p") 'bfs-previous)
    (define-key map (kbd "n") 'bfs-next)
    (define-key map (kbd "b") 'bfs-backward)
    (define-key map (kbd "f") 'bfs-forward)
    (define-key map (kbd "RET") 'bfs-forward)

    (define-key map (kbd "d") 'bfs-scroll-preview-down-half-window)
    (define-key map (kbd "s") 'bfs-scroll-preview-up-half-window)
    (define-key map (kbd "u") 'bfs-scroll-down-half-window)
    (define-key map (kbd "i") 'bfs-scroll-up-half-window)
    (define-key map (kbd "<") 'bfs-beginning-of-buffer)
    (define-key map (kbd ">") 'bfs-end-of-buffer)

    (define-key map (kbd "C-f") 'bfs-find-file)

    (define-key map (kbd "D") (lambda () (interactive) (dired default-directory)))
    (define-key map (kbd "T") (lambda () (interactive) (ansi-term "/bin/bash")))

    (define-key map (kbd "q") 'bfs-quit)
    map)
  "Keymap for `bfs-mode' used in `bfs-child-buffer-name' buffer.")

(defvar bfs-parent-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map bfs-mode-map)
    map)
  "Keymap for `bfs-mode' used in `bfs-parent-buffer-name' buffer.")

(defun bfs-mode (&optional parent)
  "Mode use in `bfs-child-buffer-name' and `bfs-parent-buffer-name'
buffers when `bfs' environment is \"activated\" with `bfs' command.

See `bfs-child-buffer' and `bfs-parent-buffer' commands."
  (interactive)
  (kill-all-local-variables)
  (setq default-directory (or parent default-directory))
  (cond ((string= (buffer-name (current-buffer)) bfs-child-buffer-name)
         (use-local-map bfs-child-mode-map))
        ((string= (buffer-name (current-buffer)) bfs-parent-buffer-name)
         (use-local-map bfs-parent-mode-map))
        (t t))
  (hl-line-mode)
  (face-remap-add-relative 'hl-line :background bfs-hl-line-background)
  (face-remap-add-relative 'hl-line :foreground bfs-hl-line-foreground)
  (if bfs-hl-line-is-bold (face-remap-add-relative 'hl-line 'bold))
  (setq major-mode 'bfs-mode
        mode-name "bfs"
        buffer-read-only t)
  (setq-local font-lock-defaults '(bfs-font-lock-keywords t nil nil)))

;;; bfs (main entry)

(defun bfs ()
  "Start a `bfs' (Browse File System) environment in the `selected-frame'.

This pops up a 3 panes (windows) layout that allow you to browse
your file system and preview files.

You can only have one `bfs' environment running at a time.

When you are in the child window (the middle window), you can:
- quit `bfs' environment with `bfs-quit',
- preview files with `bfs-next' and `bfs-previous',
- go up and down in the file system tree with `bfs-backward'
  and `bfs-forward',
- scroll the previewed file with `bfs-scroll-preview-down-half-window',
  `bfs-scroll-preview-up-half-window',
- \"jump\" to any file in your file system with `bfs-find-file', this
  automatically update `bfs' environment.

In the child window, when you move the cursor with `isearch-forward'
or `isearch-backward', this will automatically preview the file you
move to.

Any command that invalidates `bfs' environment will cause to leave
`bfs' environment.  See `bfs-check-environment'.

In the child window, the local keymap in use is `bfs-child-mode-map':

\\{bfs-child-mode-map}."
  (interactive)
  (cond
   (bfs-is-active
    (when (eq (selected-frame) bfs-frame)
      (bfs-quit)))
   (t
    (let* ((parent default-directory)
           (child-entry-initial (bfs-child-entry-initial (current-buffer))))
      (if  (not child-entry-initial)
          (message (s-concat "Files are not readable, or are too large, "
                             "or have discarded extensions, in directory: %s")
                   parent)
        (setq bfs-is-active t)
        (window-configuration-to-register :bfs)
        (setq bfs-buffer-list-before (buffer-list))
        (bfs-display (f-join parent child-entry-initial))
        (add-function :before after-delete-frame-functions 'bfs-clean-if-frame-deleted)
        (add-hook 'window-configuration-change-hook 'bfs-check-environment)
        (add-hook 'isearch-mode-end-hook 'bfs-preview-update)
        (add-hook 'isearch-update-post-hook 'bfs-preview-update))))))

(global-set-key (kbd "M-]") 'bfs)

;;; Footer

(provide 'bfs)
