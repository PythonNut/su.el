# `su.el`

This package facilitates automatic privilege escalation for file permissions using TRAMP.
You can install the package by either cloning it yourself, or by doing <kbd>M-x</kbd> `package-install` <kbd>RET</kbd> `su` <kbd>RET</kbd>.
After that, you can enable it by putting the following in your init file:

```emacs
(su-mode +1)
```

When `su-mode` is enabled, files you do not have permission to read but not write will remain editable (i.e. `buffer-read-only`  will be `nil`) and `su-mode` will indicate in the modeline that any changes made will require privilege escalation to save.
If you attempt to save your modifications, `su-mode` switches the path the buffer is visiting to a TRAMP path to the same file specifying a user able to perform the write.
If a password is required, TRAMP will ask you to enter it, after which the file will be written.
The visitation switch is permanent so you will remain authenticated thereafter.

If you do not even have permission to read the file, then `su.el` will switch the visited path immediately, allowing you to read it.

Significant effort has been made to ensure that `su.el` operates correctly. 
In particular:

1. It can use either the `su` or `sudo` methods to switch users and will automatically detect which one to use.
2. It works even if you are already using TRAMP (e.g. for editing a remote file) by adding another hop.
3. It may even work with your custom TRAMP methods, although this cannot be guaranteed.

## Example setup

```emacs
(su-mode +1)
(with-eval-after-load 'helm-files
  (su-helm-integration-mode +1))
(with-eval-after-load 'semantic/fw
  (su-semantic-integration-mode +1))
```

Note: configuration variables `su-enable-helm-integration` and `su-enable-semantic-integration` have both been replaced with minor-modes shown above. They are _not_ enabled by default, but you should enable them yourself as shown above if you use either of these packages.
