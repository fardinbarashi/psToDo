<%@ WebHandler Language="C#" Class="PsToDoApi" %>
<%@ Assembly Name="System.Web.Extensions, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35" %>
// psToDo - load/save handler for edit.html. Copied next to edit.html by
// psToDo-HTML-Report-Editable-v1.3.ps1; edit the copy in Settings\Web.
//   GET  ?action=load   -> {"version","canEdit","user","editorsGroup","data":[...]}
//   GET  ?action=whoami -> {"canEdit","user"}
//   POST ?action=save   -> body {"version","json"}
// Tools (editors only). Scripts are never run here: a request file is written to the
// queue folder and psToDo-Tools-v1.0.ps1 (scheduled task) runs it.
//   GET  ?action=tools          -> runner, runs, backups, recent saves
//   POST ?action=run            -> body {"tool","args":{}}
//   GET  ?action=runlog&id=...  -> output of one run
//   POST ?action=restore        -> body {"file"}  (a backup of monitorobjects.json)
// Saving: members of appSettings psToDo:EditorsGroup only. Version check (409 on
// conflict), backup before write, edit log. POST needs X-psToDo-Request: 1 and JSON.
// .NET Framework 4.x / C# 5.

using System;
using System.Collections;
using System.Collections.Generic;
using System.Configuration;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Web;
using System.Web.Script.Serialization;

public class PsToDoApi : IHttpHandler
{
    private static readonly object FileLock = new object();
    private const int MaxBodyBytes = 10 * 1024 * 1024;
    private static readonly string[] TriggerKeys = { "1dateTrigger", "2dateTrigger", "3dateTrigger" };

    public bool IsReusable { get { return true; } }

    public void ProcessRequest(HttpContext ctx)
    {
        ctx.Response.ContentType = "application/json";
        ctx.Response.ContentEncoding = new UTF8Encoding(false);
        ctx.Response.Cache.SetCacheability(HttpCacheability.NoCache);
        ctx.Response.Cache.SetNoStore();
        ctx.Response.AppendHeader("X-Content-Type-Options", "nosniff");

        try
        {
            if (ctx.User == null || ctx.User.Identity == null || !ctx.User.Identity.IsAuthenticated)
            {
                Fail(ctx, 401, "not-authenticated", "Sign in with Windows authentication (Anonymous must be off for this site).");
                return;
            }

            string action = (ctx.Request.QueryString["action"] ?? "").Trim().ToLowerInvariant();
            string method = ctx.Request.HttpMethod;

            if (action == "load" && method == "GET") { Load(ctx); return; }
            if (action == "whoami" && method == "GET") { WhoAmI(ctx); return; }
            if (action == "save" && method == "POST") { Save(ctx); return; }
            if (action == "tools" && method == "GET") { Tools(ctx); return; }
            if (action == "runlog" && method == "GET") { RunLog(ctx); return; }
            if (action == "run" && method == "POST") { Run(ctx); return; }
            if (action == "restore" && method == "POST") { Restore(ctx); return; }

            Fail(ctx, 405, "bad-request", "Unknown action or method.");
        }
        catch (Exception ex)
        {
            Fail(ctx, 500, "server-error", ex.GetType().Name + ": " + ex.Message);
        }
    }

    // ------------------------------------------------------------------ whoami

    private void WhoAmI(HttpContext ctx)
    {
        ctx.Response.StatusCode = 200;
        ctx.Response.Write("{\"canEdit\":" + (CanEdit(ctx) ? "true" : "false") + ",\"user\":" + Q(ctx.User.Identity.Name) + "}");
    }

    // ------------------------------------------------------------------ load

    private void Load(HttpContext ctx)
    {
        string dbPath = DbPath(ctx);
        if (!File.Exists(dbPath))
        {
            Fail(ctx, 404, "db-missing", "monitorobjects.json not found at " + dbPath + ". Check appSettings psToDo:DbPath.");
            return;
        }

        byte[] bytes;
        lock (FileLock) { bytes = File.ReadAllBytes(dbPath); }

        string text = DecodeUtf8(bytes).Trim();
        if (text.Length == 0) text = "[]";

        object parsed;
        try { parsed = Serializer().DeserializeObject(text); }
        catch (Exception ex)
        {
            Fail(ctx, 500, "db-invalid", "monitorobjects.json is not valid JSON: " + ex.Message);
            return;
        }
        if (!(parsed is object[])) text = "[" + text + "]";

        string group = EditorsGroup();
        var sb = new StringBuilder(text.Length + 256);
        sb.Append("{\"version\":").Append(Q(Hash(bytes)));
        sb.Append(",\"canEdit\":").Append(CanEdit(ctx) ? "true" : "false");
        sb.Append(",\"user\":").Append(Q(ctx.User.Identity.Name));
        sb.Append(",\"editorsGroup\":").Append(Q(group));
        sb.Append(",\"data\":").Append(text);
        sb.Append("}");
        ctx.Response.StatusCode = 200;
        ctx.Response.Write(sb.ToString());
    }

    // ------------------------------------------------------------------ save

    private static bool RequireEditor(HttpContext ctx)
    {
        if (CanEdit(ctx)) return true;
        string g = EditorsGroup();
        Fail(ctx, 403, "not-editor", g.Length == 0
            ? "Saving is turned off: no editors group is configured (appSettings psToDo:EditorsGroup)."
            : ctx.User.Identity.Name + " is not a member of " + g + ". Sign out and in again after being added.");
        return false;
    }

    // Checks a POST (CSRF header, JSON, same origin, size) and returns the body as an object, or null after Fail
    private static Dictionary<string, object> ReadPost(HttpContext ctx)
    {
        // CSRF
        if (ctx.Request.Headers["X-psToDo-Request"] != "1" ||
            !(ctx.Request.ContentType ?? "").StartsWith("application/json", StringComparison.OrdinalIgnoreCase))
        {
            Fail(ctx, 400, "bad-request", "Missing X-psToDo-Request header or JSON content type.");
            return null;
        }
        // Same origin
        string origin = ctx.Request.Headers["Origin"];
        string host = ctx.Request.Headers["Host"];
        if (string.IsNullOrEmpty(host)) host = ctx.Request.Url.Authority;
        if (!string.IsNullOrEmpty(origin))
        {
            Uri o;
            if (!Uri.TryCreate(origin, UriKind.Absolute, out o) ||
                !string.Equals(o.Authority, host, StringComparison.OrdinalIgnoreCase))
            {
                Fail(ctx, 403, "bad-origin", "Cross-site requests are not allowed.");
                return null;
            }
        }
        if (ctx.Request.ContentLength > MaxBodyBytes)
        {
            Fail(ctx, 413, "too-large", "The request is larger than " + (MaxBodyBytes / 1024 / 1024) + " MB.");
            return null;
        }

        string body;
        using (var reader = new StreamReader(ctx.Request.InputStream, Encoding.UTF8)) { body = reader.ReadToEnd(); }

        Dictionary<string, object> req;
        try { req = Serializer().DeserializeObject(body) as Dictionary<string, object>; }
        catch (Exception ex) { Fail(ctx, 400, "bad-json", "The request body is not valid JSON: " + ex.Message); return null; }
        if (req == null) { Fail(ctx, 400, "bad-request", "The request body must be a JSON object."); return null; }
        return req;
    }

    private void Save(HttpContext ctx)
    {
        if (!RequireEditor(ctx)) return;
        Dictionary<string, object> req = ReadPost(ctx);
        if (req == null) return;
        if (!(req.ContainsKey("json") && req["json"] is string))
        {
            Fail(ctx, 400, "bad-request", "Expected {\"version\":\"...\",\"json\":\"...\"}.");
            return;
        }
        string baseVersion = req.ContainsKey("version") ? Convert.ToString(req["version"], CultureInfo.InvariantCulture) : "";
        Commit(ctx, ((string)req["json"]).Trim(), baseVersion, "saved", "", true);
    }

    // Validates the new content and writes monitorobjects.json (backup first).
    // baseVersion null = no version check. checkFields false = only the structure is checked
    // (a restore must work even if the backup holds a bad date).
    private void Commit(HttpContext ctx, string newText, string baseVersion, string verb, string source, bool checkFields)
    {
        object parsedNew;
        try { parsedNew = Serializer().DeserializeObject(newText); }
        catch (Exception ex) { Fail(ctx, 400, "bad-json", "The new content is not valid JSON: " + ex.Message); return; }
        var errors = checkFields ? Validate(parsedNew as object[]) : new List<string>();
        if (!(parsedNew is object[])) errors.Insert(0, "The content must be a JSON array of objects.");
        else foreach (object item in (object[])parsedNew)
            if (!(item is Dictionary<string, object>)) { if (errors.Count == 0) errors.Add("The content must be a JSON array of objects."); break; }
        if (errors.Count > 0)
        {
            Fail(ctx, 400, "invalid", "The data was not saved: " + string.Join(" | ", errors.ToArray()));
            return;
        }
        int newCount = ((object[])parsedNew).Length;

        string dbPath = DbPath(ctx);
        string backupFolder = BackupFolder(ctx);
        string user = ctx.User.Identity.Name;
        string backupName = "";
        string newVersion;
        int oldCount = 0;

        lock (FileLock)
        {
            byte[] current = File.Exists(dbPath) ? File.ReadAllBytes(dbPath) : new byte[0];
            string currentVersion = Hash(current);
            if (baseVersion != null && !string.Equals(baseVersion, currentVersion, StringComparison.OrdinalIgnoreCase))
            {
                ctx.Response.StatusCode = 409;
                ctx.Response.Write("{\"error\":\"conflict\",\"message\":" +
                    Q("monitorobjects.json was changed by someone else (another editor or a plugin run) after you loaded it.") +
                    ",\"version\":" + Q(currentVersion) + "}");
                return;
            }

            try
            {
                object oldParsed = Serializer().DeserializeObject(DecodeUtf8(current).Trim().Length == 0 ? "[]" : DecodeUtf8(current));
                oldCount = oldParsed is object[] ? ((object[])oldParsed).Length : 1;
            }
            catch { oldCount = -1; }

            // 1. Backup (-2, -3 ... within the same second)
            if (current.Length > 0)
            {
                Directory.CreateDirectory(backupFolder);
                string baseName = "monitorobjects-" + DateTime.Now.ToString("yyyy-MM-dd_HH.mm.ss", CultureInfo.InvariantCulture) +
                                  "-web-" + SafeFilePart(user);
                backupName = baseName + ".json";
                for (int n = 2; File.Exists(Path.Combine(backupFolder, backupName)); n++)
                    backupName = baseName + "-" + n.ToString(CultureInfo.InvariantCulture) + ".json";
                File.WriteAllBytes(Path.Combine(backupFolder, backupName), current);
            }

            // 2. Temp file, then swap
            string dir = Path.GetDirectoryName(dbPath);
            Directory.CreateDirectory(dir);
            string temp = Path.Combine(dir, "monitorobjects.json.tmp-" + Guid.NewGuid().ToString("N"));
            byte[] newBytes = Encoding.UTF8.GetPreamble();
            byte[] payload = new UTF8Encoding(false).GetBytes(newText + Environment.NewLine);
            Array.Resize(ref newBytes, newBytes.Length + payload.Length);
            Array.Copy(payload, 0, newBytes, Encoding.UTF8.GetPreamble().Length, payload.Length);
            File.WriteAllBytes(temp, newBytes);
            try
            {
                if (File.Exists(dbPath)) File.Replace(temp, dbPath, null);
                else File.Move(temp, dbPath);
            }
            finally
            {
                if (File.Exists(temp)) File.Delete(temp);
            }
            newVersion = Hash(newBytes);
        }

        Audit(ctx, user + " " + verb + " " + newCount + " object(s)" + (source.Length == 0 ? "" : " from " + source) +
                   " (was " + (oldCount < 0 ? "?" : oldCount.ToString(CultureInfo.InvariantCulture)) +
                   "). Backup: " + (backupName.Length == 0 ? "(none - file was new)" : backupName));

        ctx.Response.StatusCode = 200;
        ctx.Response.Write("{\"version\":" + Q(newVersion) + ",\"backup\":" + Q(backupName) +
                           ",\"count\":" + newCount.ToString(CultureInfo.InvariantCulture) + "}");
    }

    // ------------------------------------------------------------------ tools

    private const int MaxPending = 20;
    private const int MaxListed = 30;

    private static string QueueFolder(HttpContext ctx) { return Resolve(ctx, Setting("psToDo:QueueFolder", @"..\queue")); }

    private static Dictionary<string, object> ReadJsonFile(string path)
    {
        try
        {
            if (!File.Exists(path)) return null;
            return Serializer().DeserializeObject(DecodeUtf8(File.ReadAllBytes(path))) as Dictionary<string, object>;
        }
        catch { return null; }
    }

    private static bool IsRunId(string s)
    {
        if (s == null || s.Length != 32) return false;
        foreach (char c in s) if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
        return true;
    }

    private static bool IsBackupName(string s)
    {
        if (string.IsNullOrEmpty(s) || s.Length > 200 || !s.StartsWith("monitorobjects-", StringComparison.Ordinal) ||
            !s.EndsWith(".json", StringComparison.OrdinalIgnoreCase)) return false;
        foreach (char c in s) if (!(char.IsLetterOrDigit(c) || c == '-' || c == '_' || c == '.')) return false;
        return s.IndexOf("..", StringComparison.Ordinal) < 0;
    }

    private void Tools(HttpContext ctx)
    {
        if (!RequireEditor(ctx)) return;
        string queue = QueueFolder(ctx);
        var result = new Dictionary<string, object>();

        // Runner heartbeat and tool list (written by psToDo-Tools-v1.0.ps1)
        Dictionary<string, object> runner = ReadJsonFile(Path.Combine(queue, "runner.json"));
        result["runner"] = runner;
        double age = -1;
        DateTimeOffset seen;
        if (runner != null && runner.ContainsKey("lastSeen") &&
            DateTimeOffset.TryParse(Convert.ToString(runner["lastSeen"], CultureInfo.InvariantCulture), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out seen))
            age = Math.Max(0, (DateTimeOffset.Now - seen).TotalSeconds);
        result["runnerAgeSeconds"] = Math.Round(age);

        // Queued requests and runs, newest first
        var runs = new List<Dictionary<string, object>>();
        string requests = Path.Combine(queue, "requests");
        if (Directory.Exists(requests))
            foreach (string f in Directory.GetFiles(requests, "*.json"))
            {
                Dictionary<string, object> r = ReadJsonFile(f);
                if (r == null) continue;
                r["status"] = "queued";
                runs.Add(r);
            }
        string runDir = Path.Combine(queue, "runs");
        if (Directory.Exists(runDir))
            foreach (string f in Directory.GetFiles(runDir, "*.json"))
            {
                Dictionary<string, object> r = ReadJsonFile(f);
                if (r != null) runs.Add(r);
            }
        runs.Sort(delegate(Dictionary<string, object> x, Dictionary<string, object> y)
        {
            return string.CompareOrdinal(Str(y, "requestedAt"), Str(x, "requestedAt"));
        });
        if (runs.Count > MaxListed) runs.RemoveRange(MaxListed, runs.Count - MaxListed);
        result["runs"] = runs;

        // Backups of monitorobjects.json, newest first
        var backups = new List<Dictionary<string, object>>();
        string backupFolder = BackupFolder(ctx);
        if (Directory.Exists(backupFolder))
        {
            var files = new List<FileInfo>(new DirectoryInfo(backupFolder).GetFiles("monitorobjects-*.json"));
            files.Sort(delegate(FileInfo x, FileInfo y) { return y.LastWriteTimeUtc.CompareTo(x.LastWriteTimeUtc); });
            foreach (FileInfo f in files)
            {
                if (backups.Count >= MaxListed) break;
                if (!IsBackupName(f.Name)) continue;
                var b = new Dictionary<string, object>();
                b["file"] = f.Name;
                b["modified"] = new DateTimeOffset(f.LastWriteTime).ToString("o", CultureInfo.InvariantCulture);
                b["size"] = f.Length;
                backups.Add(b);
            }
        }
        result["backups"] = backups;

        // Last lines of the edit log
        var saves = new List<string>();
        try
        {
            string log = EditLog(ctx);
            if (File.Exists(log))
            {
                string[] lines = File.ReadAllLines(log, Encoding.UTF8);
                for (int i = Math.Max(0, lines.Length - 15); i < lines.Length; i++)
                    if (lines[i].Trim().Length > 0) saves.Add(lines[i]);
                saves.Reverse();
            }
        }
        catch { }
        result["saves"] = saves;

        ctx.Response.StatusCode = 200;
        ctx.Response.Write(Serializer().Serialize(result));
    }

    private void Run(HttpContext ctx)
    {
        if (!RequireEditor(ctx)) return;
        Dictionary<string, object> req = ReadPost(ctx);
        if (req == null) return;

        string tool = Str(req, "tool");
        string queue = QueueFolder(ctx);

        // Only tools the runner has published
        Dictionary<string, object> runner = ReadJsonFile(Path.Combine(queue, "runner.json"));
        bool known = false;
        if (runner != null && runner.ContainsKey("tools") && runner["tools"] is object[])
            foreach (object t in (object[])runner["tools"])
            {
                var d = t as Dictionary<string, object>;
                if (d != null && Str(d, "id") == tool && tool.Length > 0) known = true;
            }
        if (runner == null) { Fail(ctx, 409, "no-runner", "The tools task has not run yet. Set it up with Install-help\\Setup-ToolsRunner.ps1."); return; }
        if (!known) { Fail(ctx, 400, "unknown-tool", "Unknown tool."); return; }

        // Arguments: a few short strings. The runner checks what they mean.
        var args = new Dictionary<string, object>();
        if (req.ContainsKey("args") && req["args"] != null)
        {
            var given = req["args"] as Dictionary<string, object>;
            if (given == null || given.Count > 6) { Fail(ctx, 400, "bad-request", "args must be an object with at most 6 values."); return; }
            foreach (KeyValuePair<string, object> kv in given)
            {
                string v = Convert.ToString(kv.Value, CultureInfo.InvariantCulture) ?? "";
                bool keyOk = kv.Key.Length > 0 && kv.Key.Length <= 20;
                foreach (char c in kv.Key) if (!char.IsLetter(c) || c > 'z') keyOk = false;
                bool valueOk = v.Length <= 300;
                foreach (char c in v) if (c < 0x20) valueOk = false;
                if (!keyOk || !valueOk) { Fail(ctx, 400, "bad-request", "An argument name or value is not allowed."); return; }
                args[kv.Key] = v.Trim();
            }
        }
        string argsJson = Serializer().Serialize(args);

        string requests = Path.Combine(queue, "requests");
        string id = Guid.NewGuid().ToString("N");
        string user = ctx.User.Identity.Name;

        lock (FileLock)
        {
            Directory.CreateDirectory(requests);
            string[] pending = Directory.GetFiles(requests, "*.json");
            foreach (string f in pending)
            {
                Dictionary<string, object> p = ReadJsonFile(f);
                if (p != null && Str(p, "tool") == tool && Serializer().Serialize(p.ContainsKey("args") ? p["args"] : null) == argsJson)
                {
                    ctx.Response.StatusCode = 200;
                    ctx.Response.Write("{\"id\":" + Q(Str(p, "id")) + ",\"duplicate\":true}");
                    return;
                }
            }
            if (pending.Length >= MaxPending) { Fail(ctx, 429, "queue-full", "There are already " + pending.Length + " requests waiting."); return; }

            var request = new Dictionary<string, object>();
            request["id"] = id;
            request["tool"] = tool;
            request["args"] = args;
            request["requestedBy"] = user;
            request["requestedAt"] = DateTimeOffset.Now.ToString("o", CultureInfo.InvariantCulture);

            // Name sorts by time. Written as .tmp first: the runner only reads *.json
            string name = DateTime.UtcNow.ToString("yyyyMMddHHmmssfff", CultureInfo.InvariantCulture) + "-" + id;
            string temp = Path.Combine(requests, name + ".tmp");
            File.WriteAllText(temp, Serializer().Serialize(request), new UTF8Encoding(false));
            File.Move(temp, Path.Combine(requests, name + ".json"));
        }

        Audit(ctx, user + " ordered tool " + tool + (args.Count == 0 ? "" : " " + argsJson) + " (run " + id + ")");
        ctx.Response.StatusCode = 200;
        ctx.Response.Write("{\"id\":" + Q(id) + ",\"duplicate\":false}");
    }

    private void RunLog(HttpContext ctx)
    {
        if (!RequireEditor(ctx)) return;
        string id = (ctx.Request.QueryString["id"] ?? "").Trim().ToLowerInvariant();
        if (!IsRunId(id)) { Fail(ctx, 400, "bad-request", "Unknown run."); return; }

        string path = Path.Combine(Path.Combine(QueueFolder(ctx), "logs"), id + ".txt");
        string text = "";
        if (File.Exists(path))
        {
            // The last 200 KB
            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            {
                const int max = 200 * 1024;
                if (fs.Length > max) fs.Seek(-max, SeekOrigin.End);
                using (var r = new StreamReader(fs, Encoding.UTF8, true)) { text = r.ReadToEnd(); }
            }
        }
        ctx.Response.StatusCode = 200;
        ctx.Response.Write("{\"id\":" + Q(id) + ",\"log\":" + Q(text) + "}");
    }

    private void Restore(HttpContext ctx)
    {
        if (!RequireEditor(ctx)) return;
        Dictionary<string, object> req = ReadPost(ctx);
        if (req == null) return;

        string file = Str(req, "file");
        if (!IsBackupName(file)) { Fail(ctx, 400, "bad-request", "Unknown backup."); return; }
        string path = Path.Combine(BackupFolder(ctx), file);
        if (!File.Exists(path)) { Fail(ctx, 404, "not-found", "The backup " + file + " does not exist."); return; }

        string text = DecodeUtf8(File.ReadAllBytes(path)).Trim();
        if (text.Length == 0) { Fail(ctx, 400, "invalid", "The backup is empty."); return; }
        Commit(ctx, text, null, "restored", file, false);
    }

    // ------------------------------------------------------------------ validation

    private static List<string> Validate(object[] items)
    {
        var errors = new List<string>();
        if (items == null) return errors;
        var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        for (int i = 0; i < items.Length && errors.Count < 20; i++)
        {
            var o = items[i] as Dictionary<string, object>;
            string label = "Object #" + (i + 1);
            if (o == null) { errors.Add(label + " is not an object."); continue; }

            string id = Str(o, "id");
            if (id.Length == 0) errors.Add(label + " has no id.");
            else
            {
                label = "Object " + id;
                if (!ids.Add(id)) errors.Add(label + ": the id is used twice.");
            }
            if (Str(o, "name").Length == 0) errors.Add(label + " has no name.");

            string expire = Str(o, "expireDate");
            DateTime d;
            if (expire.Length > 0 && !DateTime.TryParseExact(expire, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out d))
                errors.Add(label + ": expireDate '" + expire + "' is not yyyy-MM-dd.");

            foreach (string k in TriggerKeys)
            {
                if (!o.ContainsKey(k) || o[k] == null) continue;
                object v = o[k];
                if (v is string && ((string)v).Trim().Length == 0) continue;
                decimal n;
                if (!decimal.TryParse(Convert.ToString(v, CultureInfo.InvariantCulture), NumberStyles.Number, CultureInfo.InvariantCulture, out n) ||
                    n != decimal.Truncate(n) || n < 0 || n > 3650)
                    errors.Add(label + ": " + k + " must be a whole number of days between 0 and 3650.");
            }

            if (o.ContainsKey("mail") && o["mail"] != null)
            {
                var mail = o["mail"] as Dictionary<string, object>;
                if (mail == null) errors.Add(label + ": mail must be an object.");
                else if (mail.ContainsKey("mailRecipients") && mail["mailRecipients"] != null && !(mail["mailRecipients"] is object[]))
                    errors.Add(label + ": mailRecipients must be a list.");
            }

            // Teams on: webhook must be https (empty is allowed)
            if (o.ContainsKey("teams") && o["teams"] != null)
            {
                var teams = o["teams"] as Dictionary<string, object>;
                if (teams == null) errors.Add(label + ": teams must be an object.");
                else if (NotifyOn(o, "notifyMethodbyTeams"))
                {
                    string hook = Str(teams, "teamWebhookUrl");
                    if (hook.Length > 0 && !hook.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
                        errors.Add(label + ": teamWebhookUrl must start with https:// when Teams is on.");
                }
            }
        }
        return errors;
    }

    // Same rules as Test-NotifyFlag
    private static bool NotifyOn(Dictionary<string, object> o, string key)
    {
        if (!o.ContainsKey(key) || o[key] == null) return false;
        object v = o[key];
        if (v is bool) return (bool)v;
        string s = Convert.ToString(v, CultureInfo.InvariantCulture).Trim().ToLowerInvariant();
        return s == "true" || s == "1" || s == "yes" || s == "ja";
    }

    // ------------------------------------------------------------------ common

    private static JavaScriptSerializer Serializer()
    {
        var js = new JavaScriptSerializer();
        js.MaxJsonLength = int.MaxValue;
        js.RecursionLimit = 64;
        return js;
    }

    private static string Setting(string key, string fallback)
    {
        string v = ConfigurationManager.AppSettings[key];
        return string.IsNullOrWhiteSpace(v) ? fallback : v.Trim();
    }

    private static string Resolve(HttpContext ctx, string p)
    {
        if (Path.IsPathRooted(p)) return Path.GetFullPath(p);
        return Path.GetFullPath(Path.Combine(ctx.Server.MapPath("~"), p));
    }

    // Defaults: the site points at <psToDo>\Files\report
    private static string DbPath(HttpContext ctx)       { return Resolve(ctx, Setting("psToDo:DbPath", @"..\db\monitorobjects.json")); }
    private static string BackupFolder(HttpContext ctx) { return Resolve(ctx, Setting("psToDo:BackupFolder", @"..\backup\psToDo")); }
    private static string EditLog(HttpContext ctx)      { return Resolve(ctx, Setting("psToDo:EditLog", @"..\..\Logs\psToDo-web-edits.log")); }
    private static string EditorsGroup()                { return Setting("psToDo:EditorsGroup", ""); }

    private static bool CanEdit(HttpContext ctx)
    {
        string group = EditorsGroup();
        if (group.Length == 0) return false;
        try { return ctx.User.IsInRole(group); }
        catch { return false; }
    }

    private static void Audit(HttpContext ctx, string line)
    {
        try
        {
            string path = EditLog(ctx);
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            lock (FileLock)
            {
                File.AppendAllText(path, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) + "  " + line + Environment.NewLine, new UTF8Encoding(false));
            }
        }
        catch { }
    }

    private static string DecodeUtf8(byte[] bytes)
    {
        using (var r = new StreamReader(new MemoryStream(bytes), Encoding.UTF8, true)) { return r.ReadToEnd(); }
    }

    private static string Hash(byte[] bytes)
    {
        using (var sha = SHA256.Create())
        {
            byte[] h = sha.ComputeHash(bytes);
            var sb = new StringBuilder(64);
            foreach (byte b in h) sb.Append(b.ToString("x2", CultureInfo.InvariantCulture));
            return sb.ToString();
        }
    }

    private static string Str(Dictionary<string, object> o, string key)
    {
        if (!o.ContainsKey(key) || o[key] == null) return "";
        return Convert.ToString(o[key], CultureInfo.InvariantCulture).Trim();
    }

    private static string SafeFilePart(string s)
    {
        var sb = new StringBuilder();
        foreach (char c in s ?? "") sb.Append(char.IsLetterOrDigit(c) || c == '-' || c == '_' ? c : '_');
        return sb.Length == 0 ? "unknown" : sb.ToString();
    }

    // JSON string, < > & escaped
    private static string Q(string s)
    {
        var sb = new StringBuilder("\"");
        foreach (char c in s ?? "")
        {
            switch (c)
            {
                case '"':  sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                case '<':  sb.Append("\\u003c"); break;
                case '>':  sb.Append("\\u003e"); break;
                case '&':  sb.Append("\\u0026"); break;
                default:
                    if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    else sb.Append(c);
                    break;
            }
        }
        return sb.Append('"').ToString();
    }

    private static void Fail(HttpContext ctx, int status, string code, string message)
    {
        ctx.Response.StatusCode = status;
        ctx.Response.Write("{\"error\":" + Q(code) + ",\"message\":" + Q(message) + "}");
    }
}
