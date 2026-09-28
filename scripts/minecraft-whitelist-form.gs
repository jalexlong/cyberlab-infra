/**
 * Minecraft whitelist requests -- Google Apps Script for the form's response
 * Sheet. See "Whitelist requests" in docs/minecraft-server.md for setup.
 *
 * On each submission this resolves the Java username against Mojang and fills
 * in the account's UUID and canonical name, so a typo or a gamertag is caught
 * before anyone reviews the row. It never approves anything: the teacher ticks
 * Approved, and "Export approved as rconclt commands" produces the commands to
 * run on the server.
 *
 * The student data this touches lives in the Sheet, inside the district's
 * Google Workspace. None of it belongs in this repository.
 */

// Form question titles, exactly as written on the form.
var QUESTION_USERNAME = 'Minecraft Java username';
var QUESTION_EDITION = 'Which edition of Minecraft do you play?';

// Columns this script adds to the right of the form's own.
var COL_UUID = 'UUID';
var COL_NAME = 'Canonical name';
var COL_STATUS = 'Lookup status';
var COL_CHECKED = 'Checked at';
var COL_APPROVED = 'Approved';
var ADDED_COLUMNS = [COL_UUID, COL_NAME, COL_STATUS, COL_CHECKED, COL_APPROVED];

// Java usernames are 3-16 letters, digits or underscores. A space means it is
// almost certainly an Xbox/Microsoft gamertag rather than the Java name.
var USERNAME_PATTERN = /^[A-Za-z0-9_]{3,16}$/;

// The Paper backend approved players are added to.
var BACKEND = 'lobby';

var MOJANG_PROFILE_URL = 'https://api.mojang.com/users/profiles/minecraft/';

// Statuses that mean the row is settled and a recheck should leave it alone.
var FINAL_STATUSES = ['OK', 'Not a Java username', 'No such Java account', 'Bedrock: not supported yet'];

/** Run once from the editor to install the form-submit trigger. */
function installTrigger() {
  var sheet = SpreadsheetApp.getActive();
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === 'onFormSubmitted') {
      ScriptApp.deleteTrigger(t);
    }
  });
  ScriptApp.newTrigger('onFormSubmitted').forSpreadsheet(sheet).onFormSubmit().create();
  ensureColumns_(responseSheet_());
}

function onOpen() {
  SpreadsheetApp.getUi()
    .createMenu('Whitelist')
    .addItem('Recheck unresolved rows', 'recheckUnresolved')
    .addItem('Export approved as rconclt commands', 'exportWhitelist')
    .addToUi();
}

function onFormSubmitted(e) {
  var sheet = e.range.getSheet();
  var cols = ensureColumns_(sheet);
  checkRow_(sheet, cols, e.range.getRow());
}

/** Retry rows whose lookup failed transiently (rate limit, Mojang outage). */
function recheckUnresolved() {
  var sheet = responseSheet_();
  var cols = ensureColumns_(sheet);
  for (var row = 2; row <= sheet.getLastRow(); row++) {
    var status = String(sheet.getRange(row, cols[COL_STATUS]).getValue());
    if (FINAL_STATUSES.indexOf(status) === -1 && status.indexOf('Duplicate') !== 0) {
      checkRow_(sheet, cols, row);
      Utilities.sleep(250);
    }
  }
}

/** Show an rconclt command for every approved, resolved row. */
function exportWhitelist() {
  var sheet = responseSheet_();
  var cols = ensureColumns_(sheet);
  var rows = sheet.getRange(2, 1, Math.max(sheet.getLastRow() - 1, 1), sheet.getLastColumn()).getValues();
  var commands = buildRconCommands(rows.map(function (r) {
    return {
      approved: r[cols[COL_APPROVED] - 1] === true,
      status: r[cols[COL_STATUS] - 1],
      uuid: r[cols[COL_UUID] - 1],
      name: r[cols[COL_NAME] - 1],
    };
  }), BACKEND);
  var html = HtmlService.createHtmlOutput(
    '<p>Paste into a root shell on the Minecraft server. Adding a player who is ' +
    'already whitelisted is harmless.</p>' +
    '<textarea style="width:100%;height:320px;font-family:monospace">' +
    commands.replace(/&/g, '&amp;').replace(/</g, '&lt;') +
    '</textarea>'
  ).setWidth(640).setHeight(440);
  SpreadsheetApp.getUi().showModalDialog(html, 'Whitelist commands');
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

function checkRow_(sheet, cols, row) {
  var values = sheet.getRange(row, 1, 1, sheet.getLastColumn()).getValues()[0];
  var edition = String(values[cols[QUESTION_EDITION] - 1] || '');
  var result;
  if (/bedrock/i.test(edition)) {
    result = { status: 'Bedrock: not supported yet' };
  } else {
    result = lookupUsername(String(values[cols[QUESTION_USERNAME] - 1] || ''), fetchProfile_);
  }

  if (result.uuid) {
    var dup = findDuplicate_(sheet, cols, row, result.uuid);
    if (dup) {
      result.status = 'Duplicate of row ' + dup;
    }
  }

  sheet.getRange(row, cols[COL_UUID]).setValue(result.uuid || '');
  sheet.getRange(row, cols[COL_NAME]).setValue(result.name || '');
  sheet.getRange(row, cols[COL_STATUS]).setValue(result.status);
  sheet.getRange(row, cols[COL_CHECKED]).setValue(new Date());
  sheet.getRange(row, cols[COL_APPROVED]).insertCheckboxes();
}

function findDuplicate_(sheet, cols, row, uuid) {
  var uuids = sheet.getRange(2, cols[COL_UUID], Math.max(sheet.getLastRow() - 1, 1), 1).getValues();
  for (var i = 0; i < uuids.length; i++) {
    if (i + 2 !== row && uuids[i][0] === uuid) {
      return i + 2;
    }
  }
  return 0;
}

function fetchProfile_(username) {
  var resp = UrlFetchApp.fetch(MOJANG_PROFILE_URL + encodeURIComponent(username), {
    muteHttpExceptions: true,
  });
  return { code: resp.getResponseCode(), body: resp.getContentText() };
}

function responseSheet_() {
  return SpreadsheetApp.getActive().getSheets()[0];
}

/** Map header text to 1-based column index, appending any added column that is missing. */
function ensureColumns_(sheet) {
  var headers = sheet.getRange(1, 1, 1, Math.max(sheet.getLastColumn(), 1)).getValues()[0];
  ADDED_COLUMNS.forEach(function (name) {
    if (headers.indexOf(name) === -1) {
      headers.push(name);
      sheet.getRange(1, headers.length).setValue(name);
    }
  });
  var cols = {};
  headers.forEach(function (h, i) {
    cols[h] = i + 1;
  });
  [QUESTION_USERNAME, QUESTION_EDITION].forEach(function (q) {
    if (!cols[q]) {
      throw new Error('No column titled "' + q + '". Match the QUESTION_ constants to the form.');
    }
  });
  return cols;
}

// ---------------------------------------------------------------------------
// Pure functions: no Google services, so they can be tested outside Apps Script.
// ---------------------------------------------------------------------------

/**
 * Resolve a username to {status, uuid, name}. `fetch(username)` must return
 * {code, body} for the Mojang profile endpoint.
 */
function lookupUsername(raw, fetch) {
  var username = String(raw).trim();
  if (!USERNAME_PATTERN.test(username)) {
    return { status: 'Not a Java username' };
  }
  var resp;
  try {
    resp = fetch(username);
  } catch (err) {
    return { status: 'Lookup failed: ' + err };
  }
  if (resp.code === 200) {
    var profile = JSON.parse(resp.body);
    return { status: 'OK', uuid: dashUuid(profile.id), name: profile.name };
  }
  if (resp.code === 204 || resp.code === 404) {
    return { status: 'No such Java account' };
  }
  if (resp.code === 429) {
    return { status: 'Rate limited: recheck later' };
  }
  return { status: 'Lookup failed: HTTP ' + resp.code };
}

/** Mojang returns UUIDs undashed; whitelist.json wants them dashed. */
function dashUuid(id) {
  var s = String(id).replace(/-/g, '').toLowerCase();
  if (!/^[0-9a-f]{32}$/.test(s)) {
    throw new Error('Not a UUID: ' + id);
  }
  return [s.slice(0, 8), s.slice(8, 12), s.slice(12, 16), s.slice(16, 20), s.slice(20)].join('-');
}

/**
 * Build `rconclt <backend> whitelist add <name>` lines from rows of
 * {approved, status, uuid, name}. Paper resolves the name to the same Mojang
 * UUID the lookup found. Names are re-checked against USERNAME_PATTERN because
 * these lines are pasted into a root shell.
 */
function buildRconCommands(rows, backend) {
  var seen = {};
  var lines = [];
  rows.forEach(function (r) {
    if (r.approved && r.status === 'OK' && r.uuid && !seen[r.uuid] && USERNAME_PATTERN.test(r.name)) {
      seen[r.uuid] = true;
      lines.push('rconclt ' + backend + ' whitelist add ' + r.name);
    }
  });
  return lines.length ? lines.join('\n') + '\n' : '# No approved players to add.\n';
}

if (typeof module !== 'undefined') {
  module.exports = { lookupUsername: lookupUsername, dashUuid: dashUuid, buildRconCommands: buildRconCommands };
}
