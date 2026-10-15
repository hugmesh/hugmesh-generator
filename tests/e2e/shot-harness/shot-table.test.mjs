// shot-table.test.mjs — OFFLINE pin for the `settle.mask` row field (#563).
// No browser, no stack:  node --test shot-harness/shot-table.test.mjs
// (npm run shots:validate-unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loadTable, validate, MASK_SELECTORS } from './shot-table.mjs';

const CANVAS = '[data-testid="cf-engine-canvas"]';

/** A minimal sound table with one row; `settle` is what the case varies. */
function tableWith(settle) {
  const row = {
    persona: 'p', step: '01', slug: 'row', auth: 'anon', route: '/x',
    do: [{ action: 'expect', testid: 'something' }],
  };
  if (settle !== undefined) row.settle = settle;
  return { personas: [{ slug: 'p', issue: 1, title: 't' }], shots: [row] };
}
const problems = (settle) => validate(tableWith(settle));

test('the committed table validates, and character-forge declares its canvas mask', () => {
  const table = loadTable();
  assert.deepEqual(validate(table), []);
  const row = table.shots.find((r) => r.persona === 'games-member' && r.slug === 'character-forge');
  assert.deepEqual(row.settle, { mask: [CANVAS] });
});

test('a row without settle is unchanged', () => {
  assert.deepEqual(problems(undefined), []);
});

test('a registered mask selector is accepted', () => {
  assert.ok(MASK_SELECTORS.has(CANVAS));
  assert.deepEqual(problems({ mask: [CANVAS] }), []);
});

test('a mask selector no UI ships is rejected', () => {
  const p = problems({ mask: ['[data-testid="cf-engine-canvs"]'] });
  assert.equal(p.length, 1);
  assert.match(p[0], /not one any UI ships/);
});

test('blanket selectors are rejected the same way', () => {
  for (const sel of ['body', 'html', '*', 'canvas']) {
    assert.match(problems({ mask: [sel] }).join('\n'), /not one any UI ships/, sel);
  }
});

test('an empty or non-array mask, an unknown settle key and a non-object settle are rejected', () => {
  assert.match(problems({ mask: [] }).join('\n'), /non-empty array/);
  assert.match(problems({ mask: CANVAS }).join('\n'), /non-empty array/);
  assert.match(problems({}).join('\n'), /non-empty array/);
  assert.match(problems({ mask: [CANVAS], skip: true }).join('\n'), /unknown settle field 'skip'/);
  assert.match(problems('off').join('\n'), /must be an object/);
  assert.match(problems(null).join('\n'), /must be an object/);
});

test('a duplicated mask selector is rejected', () => {
  assert.match(problems({ mask: [CANVAS, CANVAS] }).join('\n'), /twice/);
});
