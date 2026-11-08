/**
 * ARMORY → Google Sheet sync
 *
 * Copies items sent from the private ADD page (painfullyhueman.com/inventory-and-armor/add/)
 * into this sheet as new rows, every 5 minutes.
 *
 * SETUP (one time):
 *   1. In the ARMORY Google Sheet: Extensions > Apps Script.
 *   2. Delete what's there, paste this whole file, click Save.
 *   3. Pick "setup" in the function menu at the top, click Run, and allow access.
 * After that it runs on its own. To sync right away, run "syncArmory".
 *
 * Each item is added once. Edits and deletes made on the ADD page are copied over too.
 * You can still edit the rows here; an edit on the ADD page replaces that item's whole row.
 */

var ADDED_URL = 'https://painfullyhueman.com/inventory-and-armor/added.json';

function setup() {
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === 'syncArmory') ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger('syncArmory').timeBased().everyMinutes(5).create();
  var props = PropertiesService.getScriptProperties();
  if (!props.getProperty('lastId')) props.setProperty('lastId', String(sheetMaxId_(armorySheet_())));
  syncArmory();
}

function syncArmory() {
  var lock = LockService.getScriptLock();
  if (!lock.tryLock(30000)) return;
  try {
    var sheet = armorySheet_();
    var props = PropertiesService.getScriptProperties();
    var lastId = Number(props.getProperty('lastId') || sheetMaxId_(sheet));
    var stamps = JSON.parse(props.getProperty('stamps') || '{}');   // id -> last edit copied

    var res = UrlFetchApp.fetch(ADDED_URL + '?t=' + Date.now(), { muteHttpExceptions: true });
    if (res.getResponseCode() !== 200) return;
    var items = JSON.parse(res.getContentText());

    var head = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0]
      .map(function (h) { return String(h).trim().toLowerCase(); });
    var idCol = head.indexOf('id');
    var toRow = function (it) {
      return head.map(function (h, i) { return i === idCol ? Number(it.id) : String(it[h] || ''); });
    };

    // 1. New items: one row each, after the last row with an id.
    var fresh = items.filter(function (it) { return Number(it.id) > lastId; })
      .sort(function (a, b) { return Number(a.id) - Number(b.id); });
    var add = fresh.filter(function (it) { return !it.deleted; });
    if (add.length) {
      var start = lastDataRow_(sheet, idCol + 1) + 1;
      var range = sheet.getRange(start, 1, add.length, head.length);
      range.setNumberFormat('@');   // text as typed, so names aren't turned into dates
      sheet.getRange(start, idCol + 1, add.length, 1).setNumberFormat('0');
      range.setValues(add.map(toRow));
    }
    fresh.forEach(function (it) { if (it.updated) stamps[it.id] = it.updated; });
    if (fresh.length) props.setProperty('lastId', String(fresh[fresh.length - 1].id));

    // 2. Edits and deletes made on the ADD page after the row was added.
    var changed = items.filter(function (it) {
      return Number(it.id) <= lastId && it.updated && it.updated !== stamps[it.id];
    });
    if (changed.length) {
      var ids = sheet.getRange(1, idCol + 1, sheet.getLastRow(), 1).getValues()
        .map(function (r) { return String(r[0]).trim(); });
      var dels = [];
      changed.forEach(function (it) {
        var row = ids.indexOf(String(it.id)) + 1;
        if (row > 1) {
          if (it.deleted) dels.push(row);
          else sheet.getRange(row, 1, 1, head.length).setValues([toRow(it)]);
        }
        stamps[it.id] = it.updated;
      });
      dels.sort(function (a, b) { return b - a; }).forEach(function (r) { sheet.deleteRow(r); });
    }
    props.setProperty('stamps', JSON.stringify(stamps));
  } finally {
    lock.releaseLock();
  }
}

/* The tab whose first row has "id" and "img" columns. */
function armorySheet_() {
  var sheets = SpreadsheetApp.getActive().getSheets();
  for (var i = 0; i < sheets.length; i++) {
    var s = sheets[i];
    if (s.getLastColumn() < 1) continue;
    var head = s.getRange(1, 1, 1, s.getLastColumn()).getValues()[0]
      .map(function (h) { return String(h).trim().toLowerCase(); });
    if (head.indexOf('id') !== -1 && head.indexOf('img') !== -1) return s;
  }
  throw new Error('No tab with "id" and "img" columns found.');
}

function sheetMaxId_(sheet) {
  var col = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0]
    .map(function (h) { return String(h).trim().toLowerCase(); }).indexOf('id') + 1;
  var vals = sheet.getRange(2, col, Math.max(sheet.getLastRow() - 1, 1), 1).getValues();
  return vals.reduce(function (m, r) { var n = Number(r[0]); return n > m ? n : m; }, 0);
}

function lastDataRow_(sheet, col) {
  var vals = sheet.getRange(1, col, sheet.getLastRow() || 1, 1).getValues();
  for (var r = vals.length - 1; r >= 0; r--) if (String(vals[r][0]).trim() !== '') return r + 1;
  return 1;
}
