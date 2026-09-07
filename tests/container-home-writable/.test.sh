set -xe

# Add required inputs for container support
devenv inputs add mk-shell-bin github:rrbutani/nix-mk-shell-bin
devenv inputs add nix2container github:nlewo/nix2container --follows nixpkgs

# Generate the test files
devenv shell true

# The container's HOME must be a real writable directory, not a read-only
# nix-store phantom, for a consumer that writes a dotfile into $HOME before
# creating its own workdir.
devenv container build home-writable
output=$(devenv container run home-writable)

# Both HOME sources agree, and point at the baked home.
echo "$output" | grep "HOME=/home/user"
echo "$output" | grep "PASSWD_HOME=/home/user"

# The write into $HOME succeeded.
echo "$output" | grep "machine example.invalid"

# 0700 home so staged credentials stay private. /home ships 555 (nix makes store
# outputs read-only, so the build's chmod 0755 does not survive) — still
# world-traversable, which is all uid 1000 needs to reach its home.
echo "$output" | grep "HOME_MODE=700"
echo "$output" | grep "HOME_PARENT_MODE=555"

echo "$output" | grep "home-writable ok"

echo "✓ Container HOME is writable and correctly permissioned"
