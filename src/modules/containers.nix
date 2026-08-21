{ pkgs, config, lib, self, ... }:

let
  projectName = name:
    if config.name == null
    then throw ''You need to set `name = "myproject";` or `containers.${name}.name = "mycontainer"; to be able to generate a container.''
    else config.name;
  types = lib.types;
  envContainerName = builtins.getEnv "DEVENV_CONTAINER";
  projectRoot = builtins.path { path = self; name = "source"; };

  requiredInputs = config.lib.getInputs [
    {
      name = "nix2container";
      url = "github:nlewo/nix2container";
      attribute = "containers";
      follows = [ "nixpkgs" ];
    }
    {
      name = "mk-shell-bin";
      url = "github:rrbutani/nix-mk-shell-bin";
      attribute = "containers";
    }
  ];
  nix2container = requiredInputs.nix2container.packages.${pkgs.stdenv.system};
  mk-shell-bin = requiredInputs.mk-shell-bin;
  shell = mk-shell-bin.lib.mkShellBin { drv = config.shell; nixpkgs = pkgs; };
  bash = "${pkgs.bashInteractive}/bin/bash";
  mkEntrypoint = cfg: pkgs.writeScript "entrypoint" ''
    #!${bash}

    export PATH=/bin

    source ${shell.envScript}

    # expand any envvars before exec
    cmd="`echo "$@"|${pkgs.envsubst}/bin/envsubst`"

    ${bash} -c "$cmd"
  '';
  user = "user";
  group = "user";
  uid = "1000";
  gid = "1000";
  # A WRITABLE home. Woodpecker's per-step agent preamble runs
  # `cat <<EOF > $HOME/.netrc` at the top of EVERY step (before it exports its
  # own HOME or makes its workdir) when the repo has trusted.security enabled —
  # so $HOME, resolved from this passwd entry / the serialized OCI `Env HOME`,
  # must be a writable directory or the step dies `$HOME/.netrc: No such file or
  # directory`. The old `/env` was a read-only nix-store phantom (never created
  # real, since projects push content via explicit layers with an empty
  # copyToRoot), so netrc-into-every-step broke CI (RIG-2368). `/tmp/home` is
  # baked real + uid-1000-owned by mkTmp + the perms block below, under the
  # world-writable /tmp. This single change fixes BOTH step classes: passwd-
  # resolving tools (pulumi reads $HOME from passwd, not a per-step override) and
  # the serialized `Env HOME` that command/gate steps inherit.
  homeDir = "/tmp/home";

  mkHome = path: (pkgs.runCommand "devenv-container-home" { } ''
    mkdir -p $out${homeDir}
    if [ -d ${path} ]; then
      # Copy the directory's contents into the working directory so that, e.g.,
      # the project root ends up directly under ${homeDir} rather than in a
      # hash-prefixed subdirectory.
      cp -rP ${path}/. $out${homeDir}/
    else
      # Copy a single file using its original name, dropping the store hash.
      # Preserve symlinks (-P) rather than following them: paths produced by the
      # `files` option are symlinks into the store, and their targets are not part
      # of this source path's closure, so dereferencing would fail to stat them.
      # Keeping the symlink lets Nix's output scan pull the target into the
      # closure so it ends up in the image.
      cp -P ${path} "$out${homeDir}/${baseNameOf path}"
    fi
  '');

  mkMultiHome = paths: map mkHome paths;

  homeRoots = cfg: (
    if (builtins.typeOf cfg.copyToRoot == "list")
    then cfg.copyToRoot
    else [ cfg.copyToRoot ]
  );

  # Bake /tmp (the world-writable scratch root) AND /tmp/home (the container's
  # HOME, see homeDir above). Both are created here so they exist as real image
  # directories; the perms block on mkDerivation sets /tmp to 1777 (root) and
  # /tmp/home to uid-1000 ownership so the container user can write into its home
  # (e.g. the woodpecker netrc preamble's `$HOME/.netrc`) with no runtime mkdir.
  mkTmp = (pkgs.runCommand "devenv-container-tmp" { } ''
    mkdir -p $out/tmp/home
  '');

  mkEtc = (pkgs.runCommand "devenv-container-etc" { } ''
    mkdir -p $out/etc/pam.d

    echo "root:x:0:0:System administrator:/root:${bash}" > \
          $out/etc/passwd
    echo "${user}:x:${uid}:${gid}::${homeDir}:${bash}" >> \
          $out/etc/passwd

    echo "root:!x:::::::" > $out/etc/shadow
    echo "${user}:!x:::::::" >> $out/etc/shadow

    echo "root:x:0:" > $out/etc/group
    echo "${group}:x:${gid}:" >> $out/etc/group

    cat > $out/etc/pam.d/other <<EOF
    account sufficient pam_unix.so
    auth sufficient pam_rootok.so
    password requisite pam_unix.so nullok sha512
    session required pam_unix.so
    EOF

    touch $out/etc/login.defs
  '');

  mkPerm = derivation:
    {
      path = derivation;
      mode = "0744";
      uid = lib.toInt uid;
      gid = lib.toInt gid;
      uname = user;
      gname = group;
    };


  mkDerivation = cfg: nix2container.nix2container.buildImage ({
    name = cfg.name;
    tag = cfg.version;
    initializeNixDatabase = true;
    nixUid = lib.toInt uid;
    nixGid = lib.toInt gid;

    copyToRoot = [
      (pkgs.buildEnv {
        name = "devenv-container-root";
        paths = [
          pkgs.coreutils-full
          pkgs.bashInteractive
          pkgs.su
          pkgs.sudo
          pkgs.dockerTools.usrBinEnv
        ];
        pathsToLink = [ "/bin" "/usr/bin" ];
      })
      mkEtc
      mkTmp
    ];

    maxLayers = cfg.maxLayers;

    layers =
      if cfg.enableLayerDeduplication
      then
        builtins.foldl'
          (layers: layer:
            layers ++ [
              (nix2container.nix2container.buildLayer (layer // { inherit layers; }))
            ]
          )
          [ ]
          cfg.layers
      else builtins.map (layer: nix2container.nix2container.buildLayer layer) cfg.layers
    ;

    perms = [
      {
        path = mkTmp;
        regex = "/tmp";
        mode = "1777";
        uid = 0;
        gid = 0;
        uname = "root";
        gname = "root";
      }
      # /tmp/home is the container HOME (homeDir). nix2container applies perms
      # entries in order with last-match-wins on an unanchored regex substring
      # match (nix/tar.go), and the `/tmp` regex above also matches the
      # `/tmp/home` path — so this entry MUST follow it to win. It flips
      # /tmp/home from the inherited 1777/root to 0755 owned by the container
      # user (uid/gid 1000), so the user owns its own home and can write
      # `$HOME/.netrc` there. `/tmp` itself keeps 1777/root (the `/tmp` regex
      # does not match the shorter `/tmp` path against `/tmp/home`).
      {
        path = mkTmp;
        regex = "/tmp/home";
        mode = "0755";
        uid = lib.toInt uid;
        gid = lib.toInt gid;
        uname = user;
        gname = group;
      }
    ];

    config = {
      Entrypoint = cfg.entrypoint;
      User = "${user}";
      WorkingDir = cfg.workingDir;
      Env = lib.mapAttrsToList
        (name: value:
          "${name}=${toString value}"
        )
        config.env ++ [ "HOME=${homeDir}" "USER=${user}" ];
      Cmd =
        if builtins.isList cfg.startupCommand
        then cfg.startupCommand
        else [ cfg.startupCommand ];
    };
  } // lib.optionalAttrs (cfg.fromImage != null) {
    fromImage = cfg.fromImage;
  });

  # <container> <registry> <args>
  mkCopyScript = cfg: pkgs.writeShellScript "copy-container" ''
    set -e -o pipefail

    container=$1
    shift

    if [[ "$1" == false ]]; then
      registry="${cfg.registry}"
    else
      registry="$1"
    fi
    shift

    dest="''${registry}${cfg.name}:${cfg.version}"

    if [[ $# == 0 ]]; then
      args=(${if cfg.defaultCopyArgs == [] then "" else toString cfg.defaultCopyArgs})
    else
      args=("$@")
    fi

    echo
    echo "Copying container $container to $dest"
    echo

    ${nix2container.skopeo-nix2container}/bin/skopeo --insecure-policy copy "nix:$container" "$dest" ''${args[@]}
  '';
  containerOptions = types.submodule ({ name, config, ... }: {
    options = {
      name = lib.mkOption {
        type = types.nullOr types.str;
        description = "Name of the container.";
        defaultText = "top-level name or containers.mycontainer.name";
        default = "${projectName name}-${name}";
      };

      fromImage = lib.mkOption {
        type = types.nullOr types.package;
        description = "An existing OCI base image to build on top of, built with nix2container's pullImage.";
        default = null;
      };

      version = lib.mkOption {
        type = types.nullOr types.str;
        description = "Version/tag of the container.";
        default = "latest";
      };

      copyToRoot = lib.mkOption {
        type = types.either types.path (types.listOf types.path);
        description = "Add a path to the container. Defaults to the whole git repo.";
        default = projectRoot;
        defaultText = lib.literalExpression "self";
      };

      startupCommand = lib.mkOption {
        type = types.nullOr (types.oneOf [ types.str types.package (types.listOf types.str) ]);
        description = ''
          Command to run in the container.

          Can be a string, a package, or a list of strings for individual arguments.
          Use a list when your entrypoint expects separate arguments, e.g.:
          `startupCommand = [ "-f" "/var/lib/haproxy/haproxy.cfg" ];`
        '';
        default = null;
      };

      entrypoint = lib.mkOption {
        type = types.listOf types.anything;
        description = "Entrypoint of the container.";
        default = [ (mkEntrypoint config) ];
        defaultText = lib.literalExpression "[ entrypoint ]";
      };

      workingDir = lib.mkOption {
        type = types.str;
        description = "Working directory of the container.";
        default = homeDir;
      };

      defaultCopyArgs = lib.mkOption {
        type = types.listOf types.str;
        description =
          ''
            Default arguments to pass to `skopeo copy`.
            You can override them by passing arguments to the script.
          '';
        default = [ ];
      };

      registry = lib.mkOption {
        type = types.nullOr types.str;
        description = "Registry to push the container to.";
        default = "docker-daemon:";
      };

      maxLayers = lib.mkOption {
        type = types.nullOr types.int;
        description = "Maximum number of container layers created.";
        default = 1;
      };

      enableLayerDeduplication = (lib.mkEnableOption ''
        layer deduplication using the approach described at https://blog.eigenvalue.net/2023-nix2container-everything-once/
      '') // { default = true; };

      layers = lib.mkOption {
        type = types.listOf (types.submoduleWith {
          modules = [
            {
              options = {
                deps = lib.mkOption {
                  type = types.listOf types.package;
                  description = "A list of store paths to include in the layer.";
                  default = [ ];
                };
                copyToRoot = lib.mkOption {
                  type = types.listOf types.package;
                  description = ''
                    A list of derivations copied to the image root directory.

                    Store path prefixes ``/nix/store/hash-path`` are removed in order to relocate them to the image ``/``.
                  '';
                  default = [ ];
                };
                reproducible = lib.mkOption {
                  type = types.bool;
                  description = "Whether the layer should be reproducible.";
                  default = true;
                };
                maxLayers = lib.mkOption {
                  type = types.int;
                  description = "The maximum number of layers to create.";
                  default = 1;
                };
                perms = lib.mkOption {
                  description = ''
                    A list of file permissions which are set when the tar layer is created.

                    These permissions are not written to the Nix store.
                  '';
                  default = [ ];
                  type = types.listOf (types.submoduleWith {
                    modules = [
                      {
                        options = {
                          path = lib.mkOption {
                            type = types.pathInStore;
                            description = "A store path.";
                          };
                          regex = lib.mkOption {
                            type = types.nullOr types.str;
                            description = "A regex pattern to select files or directories to apply the ``mode`` to.";
                            example = ".*";
                            default = null;
                          };
                          mode = lib.mkOption {
                            type = types.nullOr types.str;
                            description = "The numeric permissions mode to apply to all of the files matched by the ``regex``.";
                            example = "644";
                            default = null;
                          };
                          gid = lib.mkOption {
                            type = types.nullOr types.int;
                            description = "The group ID to apply to all of the files matched by the ``regex``.";
                            example = "1000";
                            default = null;
                          };
                          uid = lib.mkOption {
                            type = types.nullOr types.int;
                            description = "The user ID to apply to all of the files matched by the ``regex``.";
                            example = "1000";
                            default = null;
                          };
                          uname = lib.mkOption {
                            type = types.nullOr types.str;
                            description = "The user name to apply to all of the files matched by the ``regex``.";
                            example = "root";
                            default = null;
                          };
                          gname = lib.mkOption {
                            type = types.nullOr types.str;
                            description = "The group name to apply to all of the files matched by the ``regex``.";
                            example = "root";
                            default = null;
                          };
                        };
                      }
                    ];
                  });
                };
                ignore = lib.mkOption {
                  type = types.nullOr types.pathInStore;
                  default = null;
                  description = ''
                    A store path to ignore when building the layer. This is mainly useful to ignore the configuration file from the container layer.
                  '';
                };
              };
            }
          ];
        });
        description = "The layers to create.";
        default = [ ];
      };

      isBuilding = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Set to true when the environment is building this container.";
      };

      derivation = lib.mkOption {
        type = types.package;
        internal = true;
        default = mkDerivation config;
      };

      copyScript = lib.mkOption {
        type = types.package;
        internal = true;
        default = mkCopyScript config;
      };

      dockerRun = lib.mkOption {
        type = types.package;
        internal = true;
        default = pkgs.writeShellScript "docker-run" ''
          if [ -t 0 ]; then
            ${pkgs.docker-client}/bin/docker run -it ${config.name}:${config.version} "$@"
          else
            ${pkgs.docker-client}/bin/docker run -i ${config.name}:${config.version} "$@"
          fi
        '';
      };
    };

    config.layers = [
      {
        perms = map mkPerm (mkMultiHome (homeRoots config));
        copyToRoot = mkMultiHome (homeRoots config);
      }
    ];
  });
in
{
  options = {
    containers = lib.mkOption {
      type = types.attrsOf containerOptions;
      default = { };
      description = "Container specifications that can be built, copied and ran using `devenv container`.";
    };

    container = {
      isBuilding = lib.mkOption {
        type = types.bool;
        default = false;
        description = ''
          Devenv set it to true when the environment is a container.

          Example:
          ```nix
          { pkgs, config, lib, ... }:
          {
            packages = [ pkgs.openssl ]
            ++ lib.optionals (!config.container.isBuilding) [ pkgs.git ];
          }
          ```
        '';
      };
    };
  };

  config = lib.mkMerge [
    {
      container.isBuilding = envContainerName != "";

      containers.shell = {
        name = lib.mkDefault "shell";
        startupCommand = lib.mkDefault bash;
      };

      containers.processes = {
        name = lib.mkDefault "processes";
        startupCommand = lib.mkDefault config.procfileScript;
      };
    }
    (if envContainerName == "" then { } else {
      containers.${envContainerName}.isBuilding = true;
    })
    (lib.mkIf config.container.isBuilding {
      devenv.tmpdir = lib.mkOverride (lib.modules.defaultOverridePriority - 1) "/tmp";
      devenv.runtime = lib.mkOverride (lib.modules.defaultOverridePriority - 1) "${config.devenv.tmpdir}/devenv";
      devenv.root = lib.mkForce "${homeDir}";
      devenv.dotfile = lib.mkOverride 49 "${homeDir}/.devenv";
    })
    {
      tasks."devenv:container:copy" = {
        exec = ''
          copy_script=$(${pkgs.jq}/bin/jq -r '.copy_script' <<< "$DEVENV_TASK_INPUT")
          spec=$(${pkgs.jq}/bin/jq -r '.spec' <<< "$DEVENV_TASK_INPUT")
          registry=$(${pkgs.jq}/bin/jq -r '.registry' <<< "$DEVENV_TASK_INPUT")
          readarray -t copy_args < <(${pkgs.jq}/bin/jq -r '.copy_args[]' <<< "$DEVENV_TASK_INPUT")

          "$copy_script" "$spec" "$registry" "''${copy_args[@]}"
        '';
        showOutput = true;
      };
    }
  ];
}
