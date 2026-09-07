{ pkgs, ... }:
{
  name = "container-home-writable";

  containers = {
    # No copyToRoot, which is the default and the case that used to break: with
    # nothing arriving from a project layer, the home directory has to be baked
    # by the container itself.
    home-writable = {
      name = "home-writable";

      # A script rather than a command string. The entrypoint pipes the command
      # through envsubst, which would expand `$HOME` at entrypoint time and strip
      # any shell variable of its own; passing a package means the Cmd is just a
      # store path, so the assertions below read the real runtime environment.
      startupCommand = pkgs.writeShellScript "home-writable" ''
        set -eu
        export PATH=${pkgs.coreutils}/bin

        # HOME as the container actually serializes it.
        echo "HOME=$HOME"

        # The passwd entry must agree with it. Tools that resolve the home
        # directory from passwd rather than $HOME (the Pulumi CLI, for one) read
        # this row, so a mismatch reintroduces the failure for them even when
        # $HOME itself is correct. root is written first and the container user
        # second, so select the row by name rather than by position.
        echo "PASSWD_HOME=$(while IFS=: read -r n _ _ _ _ h _; do
          if [ "$n" = user ]; then echo "$h"; fi
        done < /etc/passwd)"

        # $HOME must already exist as a real directory. Writing a dotfile
        # straight into it is what a CI runner preamble does before creating a
        # workdir, and it fails with "No such file or directory" when $HOME is
        # only a read-only nix-store phantom.
        test -d "$HOME"
        printf 'machine example.invalid\n' > "$HOME/.netrc"
        cat "$HOME/.netrc"

        # 0700, so credentials staged in $HOME are unreadable by other uids.
        echo "HOME_MODE=$(stat -c %a "$HOME")"

        # The parent must stay traversable, or uid 1000 cannot reach a 0700
        # home. Nix makes store outputs read-only, so /home ships 555 rather
        # than the 0755 the build chmods it to; world-traversable either way,
        # and no perms entry overrides it.
        echo "HOME_PARENT_MODE=$(stat -c %a /home)"

        echo "home-writable ok"
      '';
    };
  };
}
