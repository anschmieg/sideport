import fs from 'node:fs/promises';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { decisionReviewer } from './decision-reviewer.mjs';
import { approvalQueue } from './approval.mjs';
const directory = path.dirname(fileURLToPath(import.meta.url));
export async function commandSafety(session, options = {}) {
  const config = session + '/command-guard.toml';
  await fs.writeFile(config, `[general]\ncheck_updates = false\nself_heal_hook = false\nfail_closed = true\nunverified_decision = "deny"\n[policy]\ndefault_mode = "deny"\n[packs]\nenabled = ["system.permissions", "system.services", "database", "containers", "kubernetes", "cloud", "infrastructure", "package_managers"]\n[policy.rules]\n"core.filesystem:redirect-truncate-dynamic-path" = "warn"\n[heredoc]\nenabled = true\nfallback_on_parse_error = false\nfallback_on_timeout = false\n[interactive]\nenabled = false\nverification = "code"\ntimeout_seconds = 5\ncode_length = 4\nmax_attempts = 3\nallow_non_tty_fallback = true\ndisable_in_ci = true\n`, { mode: 0o600 });
  const approve = approvalQueue(session);
  const reviewer = decisionReviewer(session, options);
  const assess = async (command, cwd, reason, context = {}) => {

    if (typeof command !== 'string' || command.length > 65536 || command.includes('\0')) throw new Error('Invalid command');
    if (reason !== undefined && (typeof reason !== 'string' || !reason.length || reason.length > 500 || /[\x00-\x1f\x7f]/.test(reason))) throw new Error('Invalid reason');
    const result = await new Promise((resolve, reject) => {
      const child = spawn(directory + '/dcg', ['test', '--stdin', '--dialect', 'posix', '--format', 'json', '--heredoc-scan', '--config', config], {
        cwd: session, env: { PATH: '/usr/bin:/bin', HOME: session, XDG_CONFIG_HOME: session, DCG_FAIL_CLOSED: '1', DCG_UNVERIFIED_DECISION: 'deny', NO_COLOR: '1', DCG_NO_UPDATE_CHECK: '1', DCG_NO_SELF_HEAL: '1' }, stdio: ['pipe', 'pipe', 'pipe']
      });
      let output = '', error = '', bytes = 0;
      const timer = setTimeout(() => child.kill('SIGKILL'), 5000);
      child.stdout.on('data', chunk => { bytes += chunk.length; if (bytes > 1024 * 1024) child.kill('SIGKILL'); else output += chunk; });
      child.stderr.on('data', chunk => { if (error.length < 4096) error += chunk; });
      child.on('error', failure => { clearTimeout(timer); reject(failure); });
      child.on('close', code => {
        clearTimeout(timer);
        try {
          if (/Failed to load config/i.test(error)) throw new Error('Invalid command-guard configuration');
          const data = JSON.parse(output);
          if (!['allow', 'deny', 'ask', 'warn'].includes(data.decision)) throw new Error('Invalid guard response');
          if (code !== 0 && !['deny', 'ask'].includes(data.decision)) throw new Error('Command guard failed');
          resolve(data);
        } catch { reject(new Error('Command could not be safely assessed; nothing executed. ' + error.slice(0, 300))); }
      });
      child.stdin.end(command);
    });
    if (result.decision === 'allow' || result.decision === 'warn') return { allowed: true, reviewed: false };
    if (!result.rule_id) return { allowed: false, status: 'assessment_failed', reason: result.reason || 'Guard could not assess this command.' };
    const review = await reviewer.review({ command, cwd, reason, risk: result.reason, rule: result.rule_id, ...context });
    if (review.decision === 'approve') return { allowed: true, reviewed: true, status: 'model_approved_once', review };
    if (review.decision === 'reject') return { allowed: false, reviewed: true, status: 'model_rejected', reason: result.reason, review };
    if (reason === undefined) return { allowed: false, status: 'approval_required', reason: result.reason, review, rule: result.rule_id,
      hint: 'If this exact command is necessary, retry run_shell with approval_reason explaining why. Sideport will ask the local user when model review is unavailable or uncertain. Do not use a terminal app to bypass the decision.' };
    if (command.length > 4000) throw new Error('Commands requiring review must be at most 4000 characters; split the operation into reviewable steps');
    const allowed = await approve('shell_command', { command, cwd, risk: result.reason + (review.recommendation ? ` Review recommendation: ${review.recommendation}; confidence ${review.confidence.toFixed(2)}, threshold ${review.threshold.toFixed(2)}. Your decision is required.` : ' Automatic review unavailable; your decision is required.'), rule: result.rule_id }, reason);
    return { allowed, reviewed: allowed, status: allowed ? 'approved_once' : 'denied', reason: result.reason, review };
  };
  assess.record = reviewer.record;
  return assess;
}
