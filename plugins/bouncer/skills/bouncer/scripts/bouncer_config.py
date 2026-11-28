"""Resolve a Bouncer option for shell scripts that run outside the plugin hook."""

import json
import os
from pathlib import Path


def plugin_option(name):
    config_dir = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
    try:
        with (config_dir / "settings.json").open() as settings:
            configs = json.load(settings).get("pluginConfigs", {})
    except (OSError, ValueError):
        configs = {}
    options = next((config.get("options", {}) for key, config in configs.items() if key.startswith("bouncer@")), {})
    value = str(options.get(name, "")).strip()
    if value:
        return value
    manifest = Path(__file__).resolve().parents[3] / ".claude-plugin" / "plugin.json"
    with manifest.open() as defaults:
        return json.load(defaults)["userConfig"][name]["default"]
