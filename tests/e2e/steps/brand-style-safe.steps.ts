// brand-style-safe.steps.ts — the Studio's stylesheet writer handed hostile
// header/footer text (hugmesh-generator#654, D19).
//
// The writer (hugmesh_studio.core.theme.chrome_css) runs in a FRESH python
// process, exactly as the Docker start path and the device builders call it; the
// text goes in through the environment, because a form feed does not survive a
// Gherkin cell or an argv rendered for a transcript. The result is judged the way
// a CSS tokenizer reads it (see stripStrings), never by whether the hostile text
// "appears" — it is supposed to appear, inside the string literal.
//
// The transcript lands in world['cli.transcript'] so `the command succeeded`
// from common.steps.ts is reused as-is. Every step text below starts with
// "the rendered stylesheet", "outside its string literals" or "I render the
// Studio brand chrome" and was grepped across steps/ before it was written.

import { expect } from '@playwright/test';
import { When, Then } from './world';
import { runCli, REPO_ROOT } from './runners';
import { CliTranscript } from './evidence';
import { studioPython } from './dimensions';
import * as path from 'node:path';

const CLI_KEY = 'cli.transcript';
const CSS_KEY = 'brand.css';

/** The named hostile texts a scenario may ask for, by the words it uses. */
const CASES: Record<string, string> = {
  'a form feed, a closing brace and url(https://x)': 'Welcome\f} .x{background:url(https://x)}',
};

// A CSS <string-token> as the tokenizer consumes it: an escaped anything, or any
// char that is not the quote, a backslash or a newline; it ends at the quote or —
// as a <bad-string-token> — just before an unescaped LF/CR/FF, or at end of input.
const STRING = /'(?:\\[\s\S]|[^'\\\n\r\f])*(?:'|(?=[\n\r\f])|$)/g;

function stripStrings(css: string): string {
  return css.replace(STRING, "''");
}

const SCRIPT = [
  'import os, sys',
  'from hugmesh_studio.core import theme',
  'surface = os.environ["HUG_SURFACE"]; text = os.environ["HUG_TEXT"]',
  'sys.stdout.write(theme.chrome_css(**{surface + "_text": text}))',
].join('\n');

When('I render the Studio brand chrome with the {string} text {string}',
  async ({ world }, surface: string, caseName: string) => {
    const text = CASES[caseName];
    expect(text, `unknown hostile text "${caseName}". Known: ${Object.keys(CASES).join(' | ')}`)
      .toBeDefined();
    expect(['header', 'footer']).toContain(surface);
    const t = runCli([studioPython(), '-c', SCRIPT], {
      cwd: path.join(REPO_ROOT, 'studio'),
      env: { HUG_SURFACE: surface, HUG_TEXT: text },
    });
    world.set(CLI_KEY, t);
    world.set(CSS_KEY, t.stdout);
  });

function css(world: { get<T>(k: string): T }): string {
  const t = world.get<CliTranscript>(CLI_KEY);
  const out = world.get<string>(CSS_KEY);
  expect(out.trim().length, `the writer printed nothing:\n${t.stderr}`).toBeGreaterThan(0);
  return out;
}

Then('the rendered stylesheet holds exactly {int} rule block', async ({ world }, n: number) => {
  const bare = stripStrings(css(world));
  expect(bare.split('{').length - 1, `opening braces outside strings in:\n${bare}`).toBe(n);
  expect(bare.split('}').length - 1, `closing braces outside strings in:\n${bare}`).toBe(n);
});

Then('outside its string literals the rendered stylesheet has no {string}',
  async ({ world }, needle: string) => {
    const bare = stripStrings(css(world));
    expect(bare, `${JSON.stringify(needle)} escaped the string literal:\n${bare}`)
      .not.toContain(needle);
  });

Then('the rendered stylesheet declares the {string} content exactly once',
  async ({ world }, surface: string) => {
    const bare = stripStrings(css(world));
    const decl = `--sd-${surface}-content:`;
    expect(bare.split(decl).length - 1, `${decl} in:\n${bare}`).toBe(1);
  });

Then('the rendered stylesheet carries no raw control character', async ({ world }) => {
  const out = css(world);
  // eslint-disable-next-line no-control-regex
  const raw = /[\x00-\x09\x0b-\x1f\x7f-\x9f]/.exec(out);   // LF is the file's own line end
  expect(raw, `raw control character U+${raw ? raw[0].charCodeAt(0).toString(16).padStart(4, '0') : ''} in:\n${JSON.stringify(out)}`)
    .toBeNull();
});
