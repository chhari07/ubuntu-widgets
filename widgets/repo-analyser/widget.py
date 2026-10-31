#!/usr/bin/env python3
"""GitHub repo analyser for the desktop, Mac-style glass card.

Pick any of your repos from the dropdown to see its stats, languages and a green
line replaying its latest merged pull request. Data comes from `gh api graphql`
using your gh login, is cached in ~/.cache/ubuntu-widgets/repo-analyser/data.json, and
refreshes every 30 minutes, after the laptop wakes, and on the refresh arrow.
Drag the card anywhere (position and repo are remembered); right-click for menu.

Runs as a single background app; `widget.py --toggle | --show | --hide | --refresh`
controls it. `--background` starts with the last visibility.
"""
import datetime as dt
import json
import os
import shutil
import subprocess
import threading
import time

os.environ.setdefault("GDK_BACKEND", "x11")  # Wayland apps can't place their own window

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("WebKit2", "4.1")
from gi.repository import Gdk, Gio, GLib, Gtk, WebKit2

HERE = os.path.dirname(os.path.abspath(__file__))
UI_URI = GLib.filename_to_uri(os.path.join(HERE, "ui.html"), None)
STATE = os.path.join(GLib.get_user_config_dir(), "ubuntu-widgets", "repo-analyser", "state.json")
CACHE = os.path.join(GLib.get_user_cache_dir(), "ubuntu-widgets", "repo-analyser", "data.json")
WIDTH, HEIGHT = 440, 334
REFRESH_EVERY = 1800
DAYS_BACK = 31  # one spare so the oldest bar is a full day in any timezone
RETRY_EVERY = 300

LIST_QUERY = """
query($after: String) {
  viewer {
    login
    repositories(first: 100, after: $after, ownerAffiliations: OWNER,
                 orderBy: {field: PUSHED_AT, direction: DESC}) {
      totalCount
      pageInfo { hasNextPage endCursor }
      nodes { name isPrivate stargazerCount primaryLanguage { name color } }
    }
  }
}"""

DETAIL_QUERY = """
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    name url isPrivate stargazerCount forkCount pushedAt
    defaultBranchRef { name target { ... on Commit { history { totalCount } } } }
    refs(refPrefix: "refs/heads/", first: 1) { totalCount }
    languages(first: 8, orderBy: {field: SIZE, direction: DESC}) {
      totalSize edges { size node { name color } }
    }
    pullRequests(first: 10, states: MERGED, orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes { number title url headRefName baseRefName mergedAt commits { totalCount } }
    }
  }
}"""

COMMITS_QUERY = """
query($owner: String!, $name: String!, $since: GitTimestamp!, $after: String) {
  repository(owner: $owner, name: $name) {
    defaultBranchRef { target { ... on Commit {
      history(first: 100, since: $since, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { committedDate }
      }
    } } }
  }
}"""


def read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def write_json(path, data):
    """Saved owner-only because the data can name private repos."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)


def graphql(query, **variables):
    gh = shutil.which("gh") or "/usr/bin/gh"
    if not os.path.exists(gh):
        raise RuntimeError("Run: sudo apt install gh, then gh auth login")
    cmd = [gh, "api", "graphql", "-f", f"query={query}"]
    for key, value in variables.items():
        if value is not None:
            cmd += ["-f", f"{key}={value}"]
    done = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    if done.returncode:
        message = (done.stderr or done.stdout).strip() or "gh failed"
        if "gh auth login" in message or "HTTP 401" in message:
            raise RuntimeError("Run: gh auth login")
        raise RuntimeError(message)
    return json.loads(done.stdout)["data"]


def fetch_repos():
    repos, after, login = [], None, None
    while True:
        viewer = graphql(LIST_QUERY, after=after)["viewer"]
        login = viewer["login"]
        page = viewer["repositories"]
        repos += page["nodes"]
        if not page["pageInfo"]["hasNextPage"]:
            return login, repos
        after = page["pageInfo"]["endCursor"]


def fetch_daily(owner, name):
    """Commits per local day on the default branch, as {"YYYY-MM-DD": count}."""
    since = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=DAYS_BACK)).strftime("%Y-%m-%dT%H:%M:%SZ")
    daily, after = {}, None
    while True:
        ref = graphql(COMMITS_QUERY, owner=owner, name=name, since=since, after=after)["repository"]["defaultBranchRef"]
        if not ref:
            return daily
        history = ref["target"]["history"]
        for commit in history["nodes"]:
            stamp = dt.datetime.fromisoformat(commit["committedDate"].replace("Z", "+00:00"))
            day = stamp.astimezone().date().isoformat()
            daily[day] = daily.get(day, 0) + 1
        if not history["pageInfo"]["hasNextPage"]:
            return daily
        after = history["pageInfo"]["endCursor"]


def fetch_detail(owner, name):
    repo = graphql(DETAIL_QUERY, owner=owner, name=name)["repository"]
    merged = repo.pop("pullRequests")["nodes"]
    repo["merge"] = max(merged, key=lambda pr: pr["mergedAt"]) if merged else None
    repo["daily"] = fetch_daily(owner, name)
    return repo


class Widget(Gtk.Window):
    def __init__(self, app, geo):
        super().__init__(title="GitHub Repo Analyser")
        self.app = app
        self.ready = False

        visual = self.get_screen().get_rgba_visual()
        if visual:
            self.set_visual(visual)
        self.set_app_paintable(True)
        self.set_decorated(False)
        self.set_resizable(False)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_type_hint(Gdk.WindowTypeHint.UTILITY)
        self.set_default_size(WIDTH, HEIGHT)
        self.stick()

        manager = WebKit2.UserContentManager()
        manager.register_script_message_handler("app")
        manager.connect("script-message-received::app", self.on_message)
        self.view = WebKit2.WebView.new_with_user_content_manager(manager)
        self.view.set_size_request(WIDTH, HEIGHT)
        self.view.set_background_color(Gdk.RGBA(0, 0, 0, 0))
        settings = self.view.get_settings()
        settings.set_hardware_acceleration_policy(WebKit2.HardwareAccelerationPolicy.NEVER)
        settings.set_enable_developer_extras(False)
        self.view.connect("decide-policy", self.on_policy)
        self.view.connect("context-menu", self.on_context_menu)
        self.view.load_uri(UI_URI)
        self.add(self.view)
        self.view.show()

        self.connect("configure-event", lambda *_: GLib.idle_add(self.app.remember) and False)
        self.connect("delete-event", lambda *_: self.app.hide() or True)

        display = Gdk.Display.get_default()
        area = (display.get_primary_monitor() or display.get_monitor(0)).get_workarea()
        self.move(geo.get("x", area.x + area.width - WIDTH - 40), geo.get("y", area.y + 40))

    def send(self, payload):
        if self.ready:
            self.view.evaluate_javascript(f"window.render({json.dumps(payload)})", -1, None, None, None, None, None)

    def on_policy(self, _view, decision, kind):
        """The page may only show ui.html; links go through the open message."""
        if kind == WebKit2.PolicyDecisionType.NAVIGATION_ACTION:
            uri = decision.get_navigation_action().get_request().get_uri()
            if uri != UI_URI:
                decision.ignore()
                return True
        return False

    def on_context_menu(self, _view, _menu, event, _hit):
        menu = Gtk.Menu()
        for text, fn in (("Refresh now", self.app.refresh), ("Open repo on GitHub", self.app.open_repo),
                         (None, None), ("Hide widget", self.app.hide)):
            menu.append(Gtk.SeparatorMenuItem() if text is None else self.item(text, fn))
        menu.show_all()
        menu.popup_at_pointer(event)
        self.menu = menu  # keep it alive while open
        return True

    @staticmethod
    def item(text, fn):
        mi = Gtk.MenuItem(label=text)
        mi.connect("activate", lambda *_: fn())
        return mi

    def on_message(self, _manager, result):
        msg = json.loads(result.get_js_value().to_string())
        kind = msg.get("type")
        if kind == "ready":
            self.ready = True
            self.app.push()
        elif kind == "select":
            self.app.select(msg["name"])
        elif kind == "refresh":
            self.app.refresh()
        elif kind == "open":
            self.app.open_url(msg["url"])
        elif kind == "drag":
            _screen, x, y = Gdk.Display.get_default().get_default_seat().get_pointer().get_position()
            self.begin_move_drag(1, x, y, Gtk.get_current_event_time())


class App(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="io.github.chhari07.UbuntuWidgets.RepoAnalyser",
                         flags=Gio.ApplicationFlags.HANDLES_COMMAND_LINE)
        self.win = None
        self.busy = False
        self.error = None
        self.detail_wanted = None
        for name, fn in (("toggle", self.toggle), ("show", self.show), ("hide", self.hide),
                         ("refresh", self.refresh)):
            action = Gio.SimpleAction.new(name, None)
            action.connect("activate", lambda *_, fn=fn: fn())
            self.add_action(action)

    def do_startup(self):
        Gtk.Application.do_startup(self)
        self.hold()  # keep running while hidden
        self.state = read_json(STATE)
        self.data = read_json(CACHE)
        self.data.setdefault("repos", [])
        self.data.setdefault("details", {})
        self.win = Widget(self, self.state)
        GLib.timeout_add_seconds(60, self.tick)
        self.watch_sleep()
        self.refresh()

    def do_command_line(self, cmd):
        args = cmd.get_arguments()[1:]
        arg = args[0].lstrip("-") if args else "show"
        if arg == "background":
            if self.state.get("visible", True):
                self.show()
        else:
            self.activate_action(arg if arg in ("toggle", "show", "hide", "refresh") else "show", None)
        return 0

    # --- visibility ---------------------------------------------------------
    def toggle(self):
        self.hide() if self.win.get_visible() else self.show()

    def show(self):
        if "x" in self.state:  # the window manager may re-place a re-shown window
            self.win.move(self.state["x"], self.state["y"])
        self.win.show()
        self.win.stick()
        self.win.present()
        self.state["visible"] = True
        write_json(STATE, self.state)

    def hide(self):
        self.remember()
        self.win.hide()
        self.state["visible"] = False
        write_json(STATE, self.state)

    def remember(self):
        if self.win.get_visible():
            self.state["x"], self.state["y"] = self.win.get_position()
            write_json(STATE, self.state)
        return False

    def open_url(self, url):
        if not url.startswith("https://github.com/"):
            return
        env = dict(os.environ)
        env.pop("GDK_BACKEND", None)
        subprocess.Popen(["xdg-open", url], env=env, start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def open_repo(self):
        repo = self.data["details"].get(self.current() or "")
        self.open_url(repo["url"] if repo else f"https://github.com/{self.data.get('login', '')}")

    # --- data ---------------------------------------------------------------
    def current(self):
        names = [r["name"] for r in self.data["repos"]]
        chosen = self.state.get("repo")
        if chosen in names:
            return chosen
        return names[0] if names else None

    def push(self):
        name = self.current()
        self.win.send({
            "login": self.data.get("login", ""), "repos": self.data["repos"], "selected": name,
            "detail": self.data["details"].get(name), "busy": self.busy, "error": self.error,
        })

    def select(self, name):
        self.state["repo"] = name
        write_json(STATE, self.state)
        self.push()
        self.load_detail(name)

    def load_detail(self, name):
        self.detail_wanted = name
        threading.Thread(target=self._fetch_detail, args=(name,), daemon=True).start()

    def _fetch_detail(self, name):
        try:
            result, err = fetch_detail(self.data["login"], name), None
        except Exception as e:  # network down, repo deleted, gh logged out
            result, err = None, str(e)
        GLib.idle_add(self._detail_done, name, result, err)

    def _detail_done(self, name, result, err):
        if result:
            self.data["details"][name] = result
            write_json(CACHE, self.data)
        if name == self.detail_wanted:
            self.error = err
            self.push()
        return False

    def refresh(self):
        if self.busy:
            return
        self.busy = True
        self.push()
        threading.Thread(target=self._fetch_all, daemon=True).start()

    def _fetch_all(self):
        try:
            login, repos = fetch_repos()
            result, err = {"login": login, "repos": repos}, None
        except Exception as e:
            result, err = None, str(e)
        GLib.idle_add(self._all_done, result, err)

    def _all_done(self, result, err):
        self.busy, self.error = False, err
        self.last_try = time.time()
        if result:
            if result["login"] != self.data.get("login"):  # gh switched accounts
                self.data["details"] = {}
            self.data.update(result, fetched=time.time())
            names = {r["name"] for r in result["repos"]}
            self.data["details"] = {k: v for k, v in self.data["details"].items() if k in names}
            write_json(CACHE, self.data)
            if self.current():
                self.load_detail(self.current())
        self.push()
        return False

    def tick(self):
        """Every minute: refresh when the interval is up, or sooner if the last try failed."""
        age = time.time() - getattr(self, "last_try", 0)
        if age >= (RETRY_EVERY if self.error else REFRESH_EVERY):
            self.refresh()
        return True

    def watch_sleep(self):
        try:
            bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
            bus.signal_subscribe("org.freedesktop.login1", "org.freedesktop.login1.Manager",
                                 "PrepareForSleep", "/org/freedesktop/login1", None,
                                 Gio.DBusSignalFlags.NONE, self.on_sleep)
        except GLib.Error:
            pass

    def on_sleep(self, _conn, _sender, _path, _iface, _signal, params):
        if not params.unpack()[0]:  # False = just woke up; give Wi-Fi a moment
            GLib.timeout_add_seconds(15, lambda: self.refresh() and False)


if __name__ == "__main__":
    raise SystemExit(App().run(__import__("sys").argv))
