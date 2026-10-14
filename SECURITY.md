# Security

- Use dedicated Steam test accounts that own nothing beyond what the test needs. Never use a personal account.
- In public repositories, workflow logs and artifacts are visible to everyone. The action writes your
  program's output to files instead of the console, but anything your program puts in `log-paths` is uploaded.
- Store the account name and password as repository secrets. Workflows started from forks do not receive
  secrets; do not work around that with `pull_request_target`.
- The Steam client's local debug port (127.0.0.1:8080) is used to fill in the sign-in form and to sign out
  at the end. It is only reachable from the runner itself.

Report security problems through GitHub's private vulnerability reporting on this repository.
