{ ... }:
{
  # A well-formed override evaluates; .test.sh proves malformed ones are rejected.
  containers.ok.homeDir = "/home/agent";
}
