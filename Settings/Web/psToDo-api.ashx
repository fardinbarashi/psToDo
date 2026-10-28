<%@ WebHandler Language="C#" Class="PsToDoApi" %>
<%@ Assembly Name="System.Web.Extensions, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35" %>
// ---------------------------------------------------------------------------------
// psToDo - save endpoint for the editable dashboard (edit.html)
//
// Lives next to edit.html in the IIS site. psToDo-HTML-Report-Editable-v1.4.ps1 copies
// it there from Settings\Web on every run; edit THIS copy, not the one in the site.
//
//   GET  psToDo-api.ashx?action=load  -> {"version","canEdit","user","editorsGroup","data":[...]}
//   POST psToDo-api.ashx?action=save  -> body {"version":"<from load>","json":"<whole file text>"}
//
// Who may do what:
//   - Reading: everyone IIS lets in (web.config URL Authorization: viewers + editors).
//   - Saving : only members of the group in appSettings "psToDo:EditorsGroup".
//              No group configured = nobody can save.
//
// Safety:
//   - The page must send the version (SHA-256 of the file) it loaded. If the file changed
//     since (another editor, a plugin run) the save is refused with 409 - nothing is lost.
//   - Every save first copies the current file to the backup folder, then writes the new
//     text to a temp file and swaps it in, so the main script never reads half a file.
//   - Every save is logged (who, when, object count, backup name) to psToDo:EditLog.
//   - POST requires the header X-psToDo-Request: 1 and a JSON body. A browser cannot send
//     that cross-site without CORS, which this handler never allows (CSRF protection).
//
// Runs as the IIS app pool identity: it needs Modify on the db folder, the backup folder
// and the log folder (Install-help\Setup-IisReportEditor.ps1 grants this).
// Written for .NET Framework 4.x / C# 5 (the compiler ASP.NET uses on Windows Server).
// ---------------------------------------------------------------------------------

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
            if (action == "save" && method == "POST") { Save(ctx); return; }

            Fail(ctx, 405, "bad-request", "Use GET ?action=load or POST ?action=save.");
        }
        catch (Exception ex)
        {
            Fail(ctx, 500, "server-error", ex.GetType().Name + ": " + ex.Message);
        }
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
        // A file holding one object (not an array) is still valid psToDo data.
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

    private void Save(HttpContext ctx)
    {
        if (!CanEdit(ctx))
        {
            string g = EditorsGroup();
            Fail(ctx, 403, "not-editor", g.Length == 0
                ? "Saving is turned off: no editors group is configured (appSettings psToDo:EditorsGroup)."
                : ctx.User.Identity.Name + " is not a member of " + g + ". Sign out and in again after being added.");
            return;
        }

        // CSRF: a custom header and a JSON content type cannot be sent cross-site without CORS.
        if (ctx.Request.Headers["X-psToDo-Request"] != "1" ||
            !(ctx.Request.ContentType ?? "").StartsWith("application/json", StringComparison.OrdinalIgnoreCase))
        {
            Fail(ctx, 400, "bad-request", "Missing X-psToDo-Request header or JSON content type.");
            return;
        }
        // Same-origin check against the Host header the browser sent (works behind load balancers too).
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
                return;
            }
        }
        if (ctx.Request.ContentLength > MaxBodyBytes)
        {
            Fail(ctx, 413, "too-large", "The request is larger than " + (MaxBodyBytes / 1024 / 1024) + " MB.");
            return;
        }

        string body;
        using (var reader = new StreamReader(ctx.Request.InputStream, Encoding.UTF8)) { body = reader.ReadToEnd(); }

        var js = Serializer();
        Dictionary<string, object> req;
        try { req = js.DeserializeObject(body) as Dictionary<string, object>; }
        catch (Exception ex) { Fail(ctx, 400, "bad-json", "The request body is not valid JSON: " + ex.Message); return; }
        if (req == null || !(req.ContainsKey("json") && req["json"] is string))
        {
            Fail(ctx, 400, "bad-request", "Expected {\"version\":\"...\",\"json\":\"...\"}.");
            return;
        }
        string baseVersion = req.ContainsKey("version") ? Convert.ToString(req["version"], CultureInfo.InvariantCulture) : "";
        string newText = ((string)req["json"]).Trim();

        // Validate the new file content before touching anything.
        object parsedNew;
        try { parsedNew = js.DeserializeObject(newText); }
        catch (Exception ex) { Fail(ctx, 400, "bad-json", "The new content is not valid JSON: " + ex.Message); return; }
        var errors = Validate(parsedNew as object[]);
        if (!(parsedNew is object[])) errors.Insert(0, "The content must be a JSON array of objects.");
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
            if (!string.Equals(baseVersion, currentVersion, StringComparison.OrdinalIgnoreCase))
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

            // 1. Backup of the current file. Two saves in the same second get -2, -3 ...
            //    so a backup is never overwritten.
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

            // 2. Write to a temp file in the same folder, then swap it in.
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

        Audit(ctx, user + " saved " + newCount + " object(s) (was " + (oldCount < 0 ? "?" : oldCount.ToString(CultureInfo.InvariantCulture)) +
                   "). Backup: " + (backupName.Length == 0 ? "(none - file was new)" : backupName));

        ctx.Response.StatusCode = 200;
        ctx.Response.Write("{\"version\":" + Q(newVersion) + ",\"backup\":" + Q(backupName) +
                           ",\"count\":" + newCount.ToString(CultureInfo.InvariantCulture) + "}");
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

            // Teams posts to a Workflows webhook. When Teams is on for the object, the URL
            // must be https (an empty URL is allowed here; the page warns about it).
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

    // Same rules as Test-NotifyFlag in the PowerShell scripts: a real boolean, or the text
    // true / 1 / yes / ja. Anything else (including a missing value) means off.
    private static bool NotifyOn(Dictionary<string, object> o, string key)
    {
        if (!o.ContainsKey(key) || o[key] == null) return false;
        object v = o[key];
        if (v is bool) return (bool)v;
        string s = Convert.ToString(v, CultureInfo.InvariantCulture).Trim().ToLowerInvariant();
        return s == "true" || s == "1" || s == "yes" || s == "ja";
    }

    // ------------------------------------------------------------------ helpers

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

    // Defaults assume the site points at <psToDo>\Files\report.
    private static string DbPath(HttpContext ctx)       { return Resolve(ctx, Setting("psToDo:DbPath", @"..\db\monitorobjects.json")); }
    private static string BackupFolder(HttpContext ctx) { return Resolve(ctx, Setting("psToDo:BackupFolder", @"..\backup\psToDo")); }
    private static string EditLog(HttpContext ctx)      { return Resolve(ctx, Setting("psToDo:EditLog", @"..\..\Logs\psToDo-web-edits.log")); }
    private static string EditorsGroup()                { return Setting("psToDo:EditorsGroup", ""); }

    private static bool CanEdit(HttpContext ctx)
    {
        string group = EditorsGroup();
        if (group.Length == 0) return false;
        try { return ctx.User.IsInRole(group); }
        catch { return false; }   // a group name that cannot be resolved = no edit rights
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
        catch { /* the save itself succeeded; a missing log must not turn it into an error */ }
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

    // JSON string literal. < > & are escaped too, so the output is safe inside HTML as well.
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
