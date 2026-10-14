# Security boundaries

Sideport grants several kinds of access separately. A connection makes the broker available; it does not itself approve every folder, provider or desktop action.

## File and shell scope

File tools enforce approved locations and reject controller paths, scope escapes and unsafe write destinations. Shell commands use an operating-system sandbox with approved folders, system/toolchain reads and writable development caches. Shell commands have network access. Shared caches can contain executable code, so these grants are a compatibility choice rather than an isolated build environment.

Command screening combines DCG with an optional decision model. Low-confidence decisions go to the user. Reviewer context comes from the requesting agent and is treated as untrusted evidence. Screening is not a proof that a script is harmless.

Sandbox jobs use separate kernel audit sessions so ordinary completion, timeout, controller exit and deliberate detachment can be cleaned up. Signal and process-inspection rules restrict sandboxed children from manipulating trusted host processes. The audit records document the adversarial checks and their coverage.

## Desktop control

Computer control requires a local approval and macOS permissions. It can operate applications beyond approved file locations, including applications that themselves have broad file or command access. The file sandbox does not confine a separately approved GUI session.

Desktop actions require a recent target where the operation supports it, and selector-based drag rechecks the selected elements. A visible local indicator is required before production desktop actions proceed. Stop disconnects the whole bridge. The outline and client label explain activity; the label is not an authenticated identity claim.

## Credentials and trusted code

Runtime keys, gateway administration, approval state, signing material and trusted helper installations are kept outside agent write grants. GitHub tokens are delivered to the credential proxy through private channels rather than exposed as real credentials to the sandboxed process. Restricted hardened signatures protect the credential-bearing helper environment under normal macOS security enforcement.

Package downloads use exact versions and audits; install scripts are disabled. Remote and managed connections have explicit admission rules. None of these checks certifies a future vendor release or a package that has no known advisory.

The verified boundary assumes normal macOS security enforcement. Same-user malware outside Sideport’s sandbox, privileged or kernel compromise, and hard resource quotas are outside the audit’s claim. The early-alpha tests do not constitute a formal security certification.

Do not include runtime credentials, signing material or unredacted controller logs in public issues. Use a minimal reproduction with synthetic paths and data when reporting a problem.
