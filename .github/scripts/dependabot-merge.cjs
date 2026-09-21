'use strict';

const { execFileSync } = require('node:child_process');
const { readFileSync } = require('node:fs');

const AUDIT_PATH = '.github/workflows/dependabot-auto-merge.yml';
const SHA = /^[a-f0-9]{40}$/;
const BAD = new Set(['failure', 'cancelled', 'timed_out', 'action_required', 'startup_failure', 'stale']);

function api(endpoint, { listKey, method = 'GET', body } = {}) {
  const args = ['api', endpoint, '--method', method];
  if (listKey !== undefined) args.push('--paginate', '--slurp');
  if (body) args.push('--input', '-');
  // Do not turn authorization, transport, or JSON errors into pending checks.
  const output = execFileSync('gh', args, {
    encoding: 'utf8', timeout: 30000,
    input: body ? JSON.stringify(body) : undefined,
    stdio: ['pipe', 'pipe', 'inherit'],
  });
  const value = JSON.parse(output);
  if (listKey === undefined) return value;
  if (!Array.isArray(value)) throw new Error('Expected paginated API response');
  return value.flatMap((page) => {
    const items = listKey === null ? page : page[listKey];
    if (!Array.isArray(items)) throw new Error(`Missing API list: ${listKey}`);
    return items;
  });
}

function latest(runs) {
  return [...runs].sort((a, b) => b.id - a.id || b.run_attempt - a.run_attempt)[0];
}

function validPull(pr, repo) {
  return pr.state === 'open' && !pr.draft && pr.user?.login === 'dependabot[bot]' &&
    pr.user?.type === 'Bot' && pr.head?.repo?.full_name === repo &&
    pr.base?.repo?.full_name === repo && SHA.test(pr.head.sha) && SHA.test(pr.base.sha);
}

function auditTitle(pr) {
  return `Dependabot audit #${pr.number} head=${pr.head.sha} base=${pr.base.sha}`;
}

function auditDecision(run, jobs) {
  if (!run || run.status !== 'completed') return { reason: 'Current-commit audit is missing or pending' };
  if (run.conclusion !== 'success') return { reason: 'Current-commit audit did not succeed' };
  const classify = jobs.find((job) => job.name === 'classify');
  const audit = jobs.find((job) => /^audit \((routine|GHSA-[a-z0-9-]+)\)$/.test(job.name));
  const held = jobs.find((job) => job.name === 'hold-zerover-minor');
  const major = jobs.find((job) => job.name === 'reject-major');
  if (classify?.conclusion !== 'success' || audit?.conclusion !== 'success' ||
      held?.conclusion !== 'skipped' || major?.conclusion !== 'skipped') {
    return { reason: 'Audit or dependency policy did not approve this commit' };
  }
  return { approved: true, security: audit.name !== 'audit (routine)' };
}

// Configuration is generated from trusted workflow triggers. Reject unsupported
// patterns rather than accidentally treating a required workflow as optional.
function matches(value, pattern) {
  if (/[\[\]{}+\\]/.test(pattern)) throw new Error(`Unsupported workflow glob: ${pattern}`);
  let regex = '^';
  for (let i = 0; i < pattern.length; i++) {
    const c = pattern[i];
    if (c === '*' && pattern[i + 1] === '*') {
      i++;
      if (pattern[i + 1] === '/') { regex += '(?:.*/)?'; i++; }
      else regex += '.*';
    } else if (c === '*') regex += '[^/]*';
    else if (c === '?') regex += '[^/]';
    else regex += c.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp(regex + '$').test(value);
}

function included(value, patterns) {
  let result = false;
  for (const pattern of patterns) {
    const negative = pattern.startsWith('!');
    if (matches(value, negative ? pattern.slice(1) : pattern)) result = !negative;
  }
  return result;
}

function applies(workflow, pr, files) {
  const trigger = workflow.trigger || {};
  if (trigger.branches && !included(pr.base.ref, trigger.branches)) return false;
  if (trigger['branches-ignore'] && included(pr.base.ref, trigger['branches-ignore'])) return false;
  if (trigger.paths && !files.some((file) => included(file, trigger.paths))) return false;
  if (trigger['paths-ignore'] && files.every((file) => included(file, trigger['paths-ignore']))) return false;
  return true;
}

function checksDecision(checks, statuses, security, baseChecks) {
  if (checks.some((c) => c.status !== 'completed')) return 'Checks still pending';
  if (statuses.some((s) => s.state !== 'success')) return 'Commit statuses are not successful';
  const failures = checks.filter((c) => BAD.has(c.conclusion));
  if (checks.some((c) => !['success', 'skipped', 'neutral'].includes(c.conclusion) && !BAD.has(c.conclusion))) {
    return 'Unknown check conclusion';
  }
  const key = (c) => `${c.app?.id}:${c.name}`;
  const baseRed = new Set(baseChecks.filter((c) => c.status === 'completed' && c.conclusion === 'failure').map(key));
  if (failures.some((c) => !security || c.conclusion !== 'failure' || !baseRed.has(key(c)))) {
    return 'Checks failed or were cancelled';
  }
  return null;
}

async function evaluate({ repo, prNumber, workflows, request = api, log = console.log, dryRun = false }) {
  const prefix = `repos/${repo}`;
  const getPull = () => request(`${prefix}/pulls/${prNumber}`);
  const pr = await getPull();
  const stop = (reason) => { log(`PR #${prNumber}: ${reason}; no merge.`); return false; };
  if (!validPull(pr, repo)) return stop('Not an open same-repository Dependabot PR');

  const audits = await request(`${prefix}/actions/workflows/dependabot-auto-merge.yml/runs?event=pull_request_target&branch=${encodeURIComponent(pr.head.ref)}&per_page=100`, { listKey: 'workflow_runs' });
  const auditRun = latest(audits.filter((r) => r.path === AUDIT_PATH && r.display_title === auditTitle(pr)));
  const auditJobs = auditRun ? await request(`${prefix}/actions/runs/${auditRun.id}/jobs?filter=latest&per_page=100`, { listKey: 'jobs' }) : [];
  const policy = auditDecision(auditRun, auditJobs);
  if (!policy.approved) return stop(policy.reason);

  const fileRows = await request(`${prefix}/pulls/${prNumber}/files?per_page=100`, { listKey: null });
  if (fileRows.length !== pr.changed_files) return stop('Changed-file list is incomplete');
  const files = fileRows.flatMap((f) => [f.filename, f.previous_filename].filter(Boolean));
  const expected = workflows.filter((w) => applies(w, pr, files));
  if (!expected.length) return stop('No required PR workflow applies');

  const runs = await request(`${prefix}/actions/runs?head_sha=${pr.head.sha}&per_page=100`, { listKey: 'workflow_runs' });
  const ciRuns = runs.filter((r) => r.event === 'pull_request' && r.head_sha === pr.head.sha &&
    r.head_repository?.full_name === repo && r.head_branch === pr.head.ref);
  const latestByWorkflow = new Map();
  for (const run of ciRuns) {
    latestByWorkflow.set(run.path, latest([run, ...(latestByWorkflow.has(run.path) ? [latestByWorkflow.get(run.path)] : [])]));
  }
  if ([...latestByWorkflow.values()].some((r) => r.status !== 'completed')) {
    return stop('A current PR workflow is still queued or running');
  }
  for (const workflow of expected) {
    const run = latest(ciRuns.filter((r) => r.path === workflow.path));
    if (!run || run.status !== 'completed') return stop(`Required workflow missing or pending: ${workflow.path}`);
    if (run.conclusion !== 'success' && !(policy.security && run.conclusion === 'failure')) {
      return stop(`Required workflow not successful: ${workflow.path}`);
    }
    const jobs = await request(`${prefix}/actions/runs/${run.id}/jobs?filter=latest&per_page=100`, { listKey: 'jobs' });
    if (!jobs.length || jobs.some((j) => j.status !== 'completed') ||
        jobs.every((j) => j.conclusion === 'skipped')) return stop(`Required workflow has no completed validation: ${workflow.path}`);
    if (run.conclusion === 'success' && jobs.some((j) => !['success', 'skipped', 'neutral'].includes(j.conclusion))) {
      return stop(`Required workflow has unsuccessful jobs: ${workflow.path}`);
    }
    if (run.conclusion === 'failure' && !jobs.some((j) => j.conclusion === 'failure')) {
      return stop(`Failed workflow has no readable failed jobs: ${workflow.path}`);
    }
  }

  const checks = await request(`${prefix}/commits/${pr.head.sha}/check-runs?filter=latest&per_page=100`, { listKey: 'check_runs' });
  const statuses = await request(`${prefix}/commits/${pr.head.sha}/status?per_page=100`, { listKey: 'statuses' });
  if (!checks.length) return stop('No check results attached to current commit');
  const baseChecks = policy.security ? await request(`${prefix}/commits/${pr.base.sha}/check-runs?filter=latest&per_page=100`, { listKey: 'check_runs' }) : [];
  const blocked = checksDecision(checks, statuses, policy.security, baseChecks);
  if (blocked) return stop(blocked);
  // A failed workflow must have a corresponding failed check, otherwise a missing
  // check payload could spend the security exception without verifying its cause.
  for (const workflow of expected) {
    const run = latest(ciRuns.filter((r) => r.path === workflow.path));
    if (run.conclusion === 'failure' && !checks.some((c) => c.check_suite?.id === run.check_suite_id && c.conclusion === 'failure')) {
      return stop('Failed workflow has no matching failed check');
    }
  }

  const fresh = await getPull();
  if (!validPull(fresh, repo) || fresh.head.sha !== pr.head.sha || fresh.base.sha !== pr.base.sha) {
    return stop('PR changed during evaluation');
  }
  if (fresh.mergeable !== true) return stop('Mergeability is unknown or conflicting');
  if (dryRun) { log(`PR #${prNumber}: eligible (dry run).`); return true; }
  // GitHub atomically checks the head SHA and enforces branch protection. Never
  // arm auto-merge: a future commit must pass this entire evaluation again.
  const result = await request(`${prefix}/pulls/${prNumber}/merge`, {
    method: 'PUT', body: { sha: pr.head.sha, merge_method: 'squash' },
  });
  if (!result.merged) throw new Error(`GitHub refused merge: ${result.message}`);
  log(`Merged PR #${prNumber} at verified head ${pr.head.sha}.`);
  return true;
}

async function main() {
  const event = JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, 'utf8'));
  const repo = process.env.GITHUB_REPOSITORY;
  const workflows = JSON.parse(readFileSync(`${__dirname}/dependabot-policy.json`, 'utf8')).workflows;
  let numbers;
  if (process.env.GITHUB_EVENT_NAME === 'workflow_dispatch') {
    numbers = [Number(event.inputs?.pull_request_number)];
  } else {
    const run = event.workflow_run;
    if (!run || !['pull_request', 'pull_request_target'].includes(run.event) || run.head_repository?.full_name !== repo) return;
    // Query current open PRs rather than trusting a stale or empty event PR list.
    const pulls = api(`repos/${repo}/pulls?state=open&head=${encodeURIComponent(repo.split('/')[0] + ':' + run.head_branch)}&per_page=100`, { listKey: null });
    numbers = pulls.map((pr) => pr.number);
  }
  for (const prNumber of numbers) {
    if (!Number.isSafeInteger(prNumber) || prNumber < 1) throw new Error('Invalid pull request number');
    await evaluate({ repo, prNumber, workflows, dryRun: process.env.DRY_RUN === 'true' });
  }
}

module.exports = { api, applies, auditDecision, auditTitle, checksDecision, evaluate, latest, matches, validPull };
if (require.main === module) main().catch((error) => { console.error(error.message); process.exitCode = 1; });
