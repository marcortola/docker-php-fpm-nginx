'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { auditTitle, auditDecision, evaluate, latest, matches, applies } = require('./dependabot-merge.cjs');

function fixture() {
  const repo = 'owner/project';
  const head = 'a'.repeat(40);
  const base = 'b'.repeat(40);
  const pr = { number: 7, state: 'open', draft: false, changed_files: 1, mergeable: true,
    user: { login: 'dependabot[bot]', type: 'Bot' },
    head: { sha: head, ref: 'dependabot/npm/group', repo: { full_name: repo } },
    base: { sha: base, ref: 'main', repo: { full_name: repo } } };
  const audit = { id: 10, path: '.github/workflows/dependabot-auto-merge.yml',
    display_title: auditTitle(pr), status: 'completed', conclusion: 'success' };
  const auditJobs = [
    { name: 'classify', conclusion: 'success' },
    { name: 'audit (routine)', conclusion: 'success' },
    { name: 'reject-major', conclusion: 'skipped' },
    { name: 'hold-zerover-minor', conclusion: 'skipped' },
  ];
  const ci = { id: 11, path: '.github/workflows/ci.yml', event: 'pull_request',
    head_sha: head, head_branch: pr.head.ref, head_repository: { full_name: repo },
    status: 'completed', conclusion: 'success', check_suite_id: 21 };
  const ciJobs = [{ name: 'build', status: 'completed', conclusion: 'success' }];
  const checks = [{ name: 'build', app: { id: 15368 }, status: 'completed', conclusion: 'success', check_suite: { id: 21 } }];
  const state = { pr, audit, auditJobs, ci, ciJobs, checks, statuses: [], baseChecks: [], mutations: [], reads: [], pulls: 0, audits: [audit], runs: [ci] };
  state.request = async (path, options = {}) => {
    state.reads.push(path);
    if (state.failAt && path.includes(state.failAt)) throw new Error('HTTP 403: Resource not accessible by integration');
    if (options.method === 'PUT') { state.mutations.push({ path, ...options }); return { merged: true }; }
    if (path.endsWith('/pulls/7')) {
      state.pulls++;
      return structuredClone(state.pulls > 1 && state.fresh ? state.fresh : state.pr);
    }
    if (path.includes('/pulls/7/files')) return [{ filename: 'package-lock.json' }];
    if (path.includes('/actions/workflows/')) return state.audits;
    if (path.includes('/actions/runs/10/jobs')) return state.auditJobs;
    if (path.includes('/actions/runs/11/jobs')) return state.ciJobs;
    if (path.includes('/actions/runs?')) return state.runs;
    if (path.includes(`/commits/${head}/check-runs`)) return state.checks;
    if (path.includes(`/commits/${base}/check-runs`)) return state.baseChecks;
    if (path.includes('/status?')) return state.statuses;
    throw new Error(`Unexpected endpoint: ${path}`);
  };
  state.evaluate = (extra = {}) => evaluate({ repo, prNumber: 7,
    workflows: [{ path: '.github/workflows/ci.yml' }], request: state.request, log: () => {}, ...extra });
  return state;
}

test('merges only verified head using atomic SHA precondition', async () => {
  const s = fixture();
  assert.equal(await s.evaluate(), true);
  assert.deepEqual(s.mutations[0].body, { sha: s.pr.head.sha, merge_method: 'squash' });
  assert.equal(s.mutations.length, 1);
});

for (const [name, change] of [
  ['missing audit', s => { s.audits = []; }],
  ['stale audit head', s => { s.audit.display_title = s.audit.display_title.replace('a'.repeat(40), 'c'.repeat(40)); }],
  ['stale audit base', s => { s.audit.display_title = s.audit.display_title.replace('b'.repeat(40), 'c'.repeat(40)); }],
  ['failed audit', s => { s.audit.conclusion = 'failure'; }],
  ['major dependency', s => { s.auditJobs[2].conclusion = 'success'; }],
  ['pre-1.0 hold', s => { s.auditJobs[3].conclusion = 'success'; }],
  ['missing hold evidence', s => { s.auditJobs.pop(); }],
  ['skipped vulnerability scan', s => { s.auditJobs[1].conclusion = 'skipped'; }],
  ['missing CI before checks attach', s => { s.runs = []; s.checks = []; }],
  ['queued CI without check runs', s => { s.ci.status = 'queued'; s.checks = []; }],
  ['cancelled CI', s => { s.ci.conclusion = 'cancelled'; }],
  ['failed CI', s => { s.ci.conclusion = 'failure'; }],
  ['all CI jobs skipped', s => { s.ciJobs[0].conclusion = 'skipped'; }],
  ['empty CI jobs', s => { s.ciJobs = []; }],
  ['failed job despite successful workflow', s => { s.ciJobs[0].conclusion = 'failure'; }],
  ['wrong CI head', s => { s.ci.head_sha = 'c'.repeat(40); }],
  ['push is not PR validation', s => { s.ci.event = 'push'; }],
  ['fork CI', s => { s.ci.head_repository.full_name = 'attacker/project'; }],
  ['wrong CI branch', s => { s.ci.head_branch = 'another-pr'; }],
  ['empty check runs', s => { s.checks = []; }],
  ['pending check', s => { s.checks[0].status = 'queued'; }],
  ['unknown check result', s => { s.checks[0].conclusion = null; }],
  ['failed check', s => { s.checks[0].conclusion = 'failure'; }],
  ['pending external status', s => { s.statuses = [{ state: 'pending' }]; }],
  ['failed external status', s => { s.statuses = [{ state: 'failure' }]; }],
  ['closed duplicate event', s => { s.pr.state = 'closed'; }],
  ['draft', s => { s.pr.draft = true; }],
  ['human-authored PR', s => { s.pr.user.login = 'human'; }],
  ['fork PR', s => { s.pr.head.repo.full_name = 'attacker/project'; }],
  ['unknown mergeability', s => { s.pr.mergeable = null; }],
  ['incomplete changed-file pagination', s => { s.pr.changed_files = 2; }],
  ['head changes before merge', s => { s.fresh = structuredClone(s.pr); s.fresh.head.sha = 'c'.repeat(40); }],
  ['base changes before merge', s => { s.fresh = structuredClone(s.pr); s.fresh.base.sha = 'c'.repeat(40); }],
]) {
  test(`does not merge: ${name}`, async () => {
    const s = fixture(); change(s);
    assert.equal(await s.evaluate(), false);
    assert.equal(s.mutations.length, 0);
  });
}

test('API authorization failure is immediate and cannot merge', async () => {
  const s = fixture(); s.failAt = '/actions/runs?';
  await assert.rejects(s.evaluate(), /HTTP 403/);
  assert.equal(s.mutations.length, 0);
  assert.equal(s.reads.filter(p => p.includes(s.failAt)).length, 1);
});

test('dry run performs no mutations', async () => {
  const s = fixture(); assert.equal(await s.evaluate({ dryRun: true }), true);
  assert.equal(s.mutations.length, 0);
});

test('latest failed run supersedes older successful run', async () => {
  const s = fixture(); s.runs.push({ ...s.ci, id: 12, conclusion: 'failure' });
  assert.equal(await s.evaluate(), false);
  assert.equal(s.mutations.length, 0);
});

test('queued additional PR workflow blocks before its checks attach', async () => {
  const s = fixture(); s.runs.push({ ...s.ci, id: 12, path: '.github/workflows/extra.yml', status: 'queued' });
  assert.equal(await s.evaluate(), false);
});

test('duplicate completion after merge performs no second merge', async () => {
  const s = fixture();
  assert.equal(await s.evaluate(), true);
  s.pr.state = 'closed';
  assert.equal(await s.evaluate(), false);
  assert.equal(s.mutations.length, 1);
});

test('security exemption requires same failed check identity on base', async () => {
  const s = fixture(); s.auditJobs[1].name = 'audit (GHSA-abcd-1234-5678)';
  s.ci.conclusion = s.ciJobs[0].conclusion = s.checks[0].conclusion = 'failure';
  s.baseChecks = structuredClone(s.checks);
  assert.equal(await s.evaluate(), true);
});

test('routine update never spends red-base exemption', async () => {
  const s = fixture(); s.ci.conclusion = s.ciJobs[0].conclusion = s.checks[0].conclusion = 'failure';
  s.baseChecks = structuredClone(s.checks);
  assert.equal(await s.evaluate(), false);
});

test('security exemption cannot use another app with same check name', async () => {
  const s = fixture(); s.auditJobs[1].name = 'audit (GHSA-abcd-1234-5678)';
  s.ci.conclusion = s.ciJobs[0].conclusion = s.checks[0].conclusion = 'failure';
  s.baseChecks = structuredClone(s.checks); s.baseChecks[0].app.id = 999;
  assert.equal(await s.evaluate(), false);
});

test('security exception cannot excuse failed workflow without failed checks', async () => {
  const s = fixture(); s.auditJobs[1].name = 'audit (GHSA-abcd-1234-5678)';
  s.ci.conclusion = s.ciJobs[0].conclusion = 'failure';
  assert.equal(await s.evaluate(), false);
});

test('workflow applicability honors paths and branch filters', () => {
  const { pr } = fixture();
  assert.equal(applies({ trigger: { paths: ['docs/**'] } }, pr, ['docs/nested/a.md']), true);
  assert.equal(applies({ trigger: { paths: ['docs/**', '!docs/private/**'] } }, pr, ['docs/private/a.md']), false);
  assert.equal(applies({ trigger: { branches: ['release'] } }, pr, ['package.json']), false);
  assert.equal(applies({ trigger: { 'paths-ignore': ['docs/**'] } }, pr, ['package.json']), true);
  assert.equal(applies({ trigger: { 'paths-ignore': ['docs/**'] } }, pr, ['docs/a.md']), false);
  assert.equal(matches('package.json', '**/package.json'), true);
  assert.equal(matches('a/package.json', '**/package.json'), true);
  assert.equal(matches('a/b/c', 'a/*'), false);
  assert.throws(() => matches('a', '[abc]'), /Unsupported/);
});

test('no applicable required workflows is not permission to merge', async () => {
  const s = fixture(); assert.equal(await s.evaluate({ workflows: [] }), false);
});

test('latest audit attempt wins and missing policy is not approval', () => {
  assert.equal(latest([{ id: 1, run_attempt: 1 }, { id: 1, run_attempt: 2 }]).run_attempt, 2);
  assert.equal(auditDecision(undefined, []).approved, undefined);
});
