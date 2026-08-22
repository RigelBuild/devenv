{ pkgs, config, lib, self, ... }:

let
  projectName = name:
    if config.name == null
    then throw ''You need to set `name = "myproject";` or `containers.${name}.name = "mycontainer"; to be able to generate a container.''
    else config.name;
  types = lib.types;
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
  # Default container identity. Per-container overridable via the `user` /
  # `group` / `homeDir` options below — the uid/gid stay module-wide because
  # nix2container's `nixUid`/`nixGid` and the initialized Nix DB are built around
  # a single numeric owner, and nothing has needed to move it.
  defaultUser = "user";
  defaultGroup = "user";
  uid = "1000";
  gid = "1000";
  # A WRITABLE home, baked real and uid-1000-owned at 0700 (mkHomeDir + the perms
  # block on mkDerivation). Woodpecker's per-step agent preamble runs
  # `cat <<EOF > $HOME/.netrc` at the top of EVERY step (before it exports its own
  # HOME or makes its workdir) when the repo has trusted.security enabled — so
  # $HOME, resolved from the passwd entry / the serialized OCI `Env HOME`, must be
  # a writable directory or the step dies `$HOME/.netrc: No such file or
  # directory`. The old `/env` was a read-only nix-store phantom (never created
  # real, since projects push content via explicit layers with an empty
  # copyToRoot), so netrc-into-every-step broke CI (RIG-2368). It is deliberately
  # NOT under /tmp: /tmp is the path a container runtime is most likely to mount
  # over (a tmpfs/scratch volume at container start), which would shadow a baked
  # /tmp/home and recur this bug; a home under a dedicated parent has no such
  # shadow. 0700 (not 0755) keeps $HOME/.netrc — git + pulumi credentials —
  # unreadable by any other uid in the container. This fixes BOTH step classes:
  # passwd-resolving tools (pulumi reads $HOME from passwd, not a per-step
  # override) and the serialized `Env HOME` that command/gate steps inherit.
  defaultHomeDir = "/home/user";

  # Resolve a container's identity from its config. Everything that bakes identity
  # into the image (the passwd/group/shadow rows, the $HOME directory, file
  # ownership, the image config's User/HOME/USER) reads through these so a single
  # option set moves all of them together.
  cfgUser = cfg: cfg.user;
  cfgGroup = cfg: cfg.group;
  cfgHomeDir = cfg: cfg.homeDir;

  # The homeDir of the container currently being built, for the module-scope
  # devenv.root/dotfile overrides below. The container being built is found from
  # config only: the backend re-evaluates the module tree once per container with
  # that container's `isBuilding` forced true
  # (devenv-nix-backend/bootstrap/bootstrapLib.nix, `mkContainerBuilds`), and that
  # `mkForce` is the single source of truth — nothing else ever sets `isBuilding`,
  # so at most one container carries it and this lookup is deterministic. Falls
  # back to the default when no container is building, so evaluation never depends
  # on a container that does not exist.
  buildingContainer =
    lib.findFirst (cfg: cfg.isBuilding) null (lib.attrValues config.containers);
  buildingHomeDir =
    if buildingContainer == null
    then defaultHomeDir
    else buildingContainer.homeDir;

  mkHome = cfg: path: (pkgs.runCommand "devenv-container-home" { } ''
    mkdir -p $out${cfgHomeDir cfg}
    if [ -d ${path} ]; then
      # Copy the directory's contents into the working directory so that, e.g.,
      # the project root ends up directly under ${cfgHomeDir cfg} rather than in a
      # hash-prefixed subdirectory.
      cp -rP ${path}/. $out${cfgHomeDir cfg}/
    else
      # Copy a single file using its original name, dropping the store hash.
      # Preserve symlinks (-P) rather than following them: paths produced by the
      # `files` option are symlinks into the store, and their targets are not part
      # of this source path's closure, so dereferencing would fail to stat them.
      # Keeping the symlink lets Nix's output scan pull the target into the
      # closure so it ends up in the image.
      cp -P ${path} "$out${cfgHomeDir cfg}/${baseNameOf path}"
    fi
  '');

  mkMultiHome = cfg: paths: map (mkHome cfg) paths;

  homeRoots = cfg: (
    if (builtins.typeOf cfg.copyToRoot == "list")
    then cfg.copyToRoot
    else [ cfg.copyToRoot ]
  );

  # The world-writable scratch root. Kept root-owned 1777 by the perms block on
  # mkDerivation (sticky, so any uid can create scratch but not clobber another's).
  mkTmp = (pkgs.runCommand "devenv-container-tmp" { } ''
    mkdir -p $out/tmp
  '');

  # The container's writable HOME (the resolved homeDir). Baked as a real image
  # directory here so $HOME exists with no runtime mkdir; the perms block on
  # mkDerivation sets the home itself uid-1000-owned at 0700 so the container user
  # (and only it) can write `$HOME/.netrc` etc. Not under /tmp — see defaultHomeDir
  # above for why a /tmp-based home is shadow-prone. The intermediate parent
  # (homeDir's dirname, e.g. `/home`) is chmod'd 0755 explicitly (not left to the
  # build umask) so it is deterministically world-traversable: uid-1000 must be
  # able to traverse it to reach its 0700 home, and the parent gets no perms entry
  # (the perms regex matches only the home itself), so its mode is whatever this
  # derivation bakes.
  mkHomeDir = cfg: (pkgs.runCommand "devenv-container-home-dir" { } ''
    mkdir -p $out${cfgHomeDir cfg}
    chmod 0755 $out${builtins.dirOf (cfgHomeDir cfg)}
  '');

  mkEtc = cfg: (pkgs.runCommand "devenv-container-etc" { } ''
    mkdir -p $out/etc/pam.d

    echo "root:x:0:0:System administrator:/root:${bash}" > \
          $out/etc/passwd
    echo "${cfgUser cfg}:x:${uid}:${gid}::${cfgHomeDir cfg}:${bash}" >> \
          $out/etc/passwd

    echo "root:!x:::::::" > $out/etc/shadow
    echo "${cfgUser cfg}:!x:::::::" >> $out/etc/shadow

    echo "root:x:0:" > $out/etc/group
    echo "${cfgGroup cfg}:x:${gid}:" >> $out/etc/group

    cat > $out/etc/pam.d/other <<EOF
    account sufficient pam_unix.so
    auth sufficient pam_rootok.so
    password requisite pam_unix.so nullok sha512
    session required pam_unix.so
    EOF

    touch $out/etc/login.defs
  '');

  mkPerm = cfg: derivation:
    {
      path = derivation;
      mode = "0744";
      uid = lib.toInt uid;
      gid = lib.toInt gid;
      uname = cfgUser cfg;
      gname = cfgGroup cfg;
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
      (mkEtc cfg)
      mkTmp
      # For a consumer with a non-empty copyToRoot, the resolved homeDir is also
      # baked by the project home layer (mkHome, 0744 uid-1000, project contents).
      # Both land the same dir in different layers; the customizationLayer is
      # assembled LAST (nix2container default.nix), so mkHomeDir's 0700 dir mode
      # is authoritative while the project contents underneath survive at 0744.
      # A consumer with copyToRoot=[] (an image that carries no repo) never runs
      # mkHome, so only this empty 0700 home exists — but the 0700 mode's
      # authority relies on that layer ordering for any default consumer.
      (mkHomeDir cfg)
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
      # The container HOME (the resolved homeDir), from its own store path
      # (mkHomeDir). Owned by the container user (uid/gid 1000) at 0700 so only
      # the user can read/write it — $HOME holds .netrc (git + pulumi creds), so
      # group/other get nothing. nix2container matches perms.regex as an unanchored
      # substring against the source store path (nix/tar.go), and this entry's
      # path is `mkHomeDir cfg` (a different derivation from mkTmp), so it is
      # scoped to the home alone and cannot collide with the /tmp entry above. The
      # regex is regex-escaped: `homeDir` is a free-form `types.str`, so a path
      # holding regex syntax (`+`, `(`, `.`) would otherwise reach
      # `regexp.MustCompile` as a pattern — panicking the build or matching paths
      # never named.
      {
        path = (mkHomeDir cfg);
        regex = lib.strings.escapeRegex (cfgHomeDir cfg);
        mode = "0700";
        uid = lib.toInt uid;
        gid = lib.toInt gid;
        uname = cfgUser cfg;
        gname = cfgGroup cfg;
      }
    ];

    config = {
      Entrypoint = cfg.entrypoint;
      User = "${cfgUser cfg}";
      WorkingDir = cfg.workingDir;
      Env = lib.mapAttrsToList
        (name: value:
          "${name}=${toString value}"
        )
        config.env ++ [ "HOME=${cfgHomeDir cfg}" "USER=${cfgUser cfg}" ];
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

      user = lib.mkOption {
        type = types.str;
        description = ''
          Unix user name baked into the container's passwd/shadow entry, its
          image config `User`, and `$USER`. The uid stays 1000 regardless — it is
          what nix2container's `nixUid` and the initialized Nix DB are built
          around — so this renames the account, it does not renumber it.
        '';
        default = defaultUser;
      };

      group = lib.mkOption {
        type = types.str;
        description = "Unix group name baked into the container's group entry. The gid stays 1000.";
        default = defaultGroup;
      };

      homeDir = lib.mkOption {
        type = types.str;
        description = ''
          The container user's `$HOME`: its passwd home field, the `HOME` in the
          image config, the staged (and uid-owned) home directory, and the
          default `workingDir`. Set this when the image must match a home path
          an external supervisor execs with — a mismatch makes nix, direnv and
          devenv fall back to the passwd home ("$HOME is not owned by you").
        '';
        default = defaultHomeDir;
      };

      workingDir = lib.mkOption {
        type = types.str;
        description = "Working directory of the container.";
        default = config.homeDir;
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
        perms = map (mkPerm config) (mkMultiHome config (homeRoots config));
        copyToRoot = mkMultiHome config (homeRoots config);
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
      containers.shell = {
        name = lib.mkDefault "shell";
        startupCommand = lib.mkDefault bash;
      };

      containers.processes = {
        name = lib.mkDefault "processes";
        startupCommand = lib.mkDefault config.procfileScript;
      };
    }
    (lib.mkIf config.container.isBuilding {
      devenv.tmpdir = lib.mkOverride (lib.modules.defaultOverridePriority - 1) "/tmp";
      devenv.runtime = lib.mkOverride (lib.modules.defaultOverridePriority - 1) "${config.devenv.tmpdir}/devenv";
      # The building container's own home, not the module default: `homeDir` is
      # per-container now, and `buildingHomeDir` reads it off the one container the
      # backend forced `isBuilding` on.
      devenv.root = lib.mkForce buildingHomeDir;
      devenv.dotfile = lib.mkOverride 49 "${buildingHomeDir}/.devenv";
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
