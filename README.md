# Zigram

A Terminal User Interface (TUI) Telegram client written in Zig.

## Prerequisites

- Zig 0.15.2 or later
- A Telegram account

**Note**: TDLib (Telegram Database Library) is automatically downloaded during the build process via `build.zig`.

## Configuration

### Telegram API Credentials

To use Zigram, you need to obtain API credentials from Telegram:

1. Go to https://my.telegram.org/auth
2. Log in with your phone number
3. Navigate to "API development tools"
4. Create a new application to get your `api_id` and `api_hash`

Set the credentials as environment variables:

```bash
export API_ID="your_api_id"
export API_HASH="your_api_hash"
```

**Tip**: Add these to your `~/.bashrc`, `~/.zshrc`, or equivalent shell configuration file to make them persistent.

**Note**: If these environment variables are not set, Zigram will use default test credentials (not recommended for production use).

### Keybindings

You can customize keybindings by creating or editing `~/.config/zigram/zigram.json`:

```json
{
  "keybindings": {
    "quit": "q",
    "quit_ctrl": "ctrl+c",
    "switch_mode": "tab",
    "navigate_up": "k",
    "navigate_up_alt": "up",
    "navigate_down": "j",
    "navigate_down_alt": "down",
    "select": "enter",
    "backspace": "backspace",
    "reload_config": "ctrl+r",
    "toggle_right_panel": "ctrl+t"
  }
}
```

#### Default Keybindings

| Action | Default Key | Description |
|--------|------------|-------------|
| Quit | `q` or `Ctrl+C` | Exit the application |
| Switch Mode | `Tab` | Cycle between Chat, LLM, and Chat List modes |
| Navigate Up | `k` or `↑` | Move up in chat list |
| Navigate Down | `j` or `↓` | Move down in chat list |
| Select | `Enter` | Select chat or send message |
| Delete Character | `Backspace` | Delete character in input field |
| Reload Config | `Ctrl+R` | Reload keybindings from config file |
| Toggle Right Panel | `Ctrl+T` | Toggle between AI Assistant and Logs |

After modifying keybindings, press `Ctrl+R` within the application to reload the configuration without restarting.

## Usage Modes

Zigram has three input modes:

1. **Chat Mode**: Type and send messages in the selected chat
2. **LLM Mode**: Interact with the AI assistant (right panel)
3. **Chat List Mode**: Navigate and select chats

Press `Tab` to cycle between modes.

## Panels

The interface is divided into three panels:

- **Left Panel**: Chat list - shows your recent conversations
- **Center Panel**: Main chat window - displays messages from the selected chat
- **Right Panel**: Toggles between:
  - **AI Assistant**: Chat with an AI (placeholder)
  - **Logs**: Real-time application logs

## Log File

Zigram writes logs to:

```
~/.local/share/zigram/zigram.log
```

Logs include:
- Application startup/shutdown events
- Telegram operations (loading chats, sending messages)
- Configuration reloads
- Error messages

You can view logs in real-time by toggling the right panel to "Logs" mode using `Ctrl+T`.

## Building

```bash
zig build
```

The build script will automatically download TDLib if not already present.

## Running

```bash
# Make sure to set your API credentials first
export API_ID="your_api_id"
export API_HASH="your_api_hash"

zig build run
```

Or after building:

```bash
./zig-out/bin/zigram
```

## First Run

On first run, Zigram will:
1. Prompt you to enter your phone number (with country code, e.g., +1234567890)
2. Send you a verification code via Telegram
3. Ask you to enter the code
4. If you have 2FA enabled, ask for your password

Your session will be saved, so you won't need to authenticate again unless you log out.

## Directory Structure

```
~/.config/zigram/
└── zigram.json      # Keybindings configuration

~/.local/share/zigram/
└── zigram.log       # Application logs

<project_root>/.data/tdlib/
└── ...              # Telegram session data (managed by TDLib)
```

## Troubleshooting

### Authentication Issues

If you encounter authentication problems:
1. Verify your `API_ID` and `API_HASH` environment variables are set correctly
2. Check the log file at `~/.local/share/zigram/zigram.log` for error messages
3. Delete the TDLib data directory (`.data/tdlib/` in the project root) to start fresh

### Configuration Not Loading

- Ensure `~/.config/zigram/zigram.json` is valid JSON (use a JSON validator)
- Check file permissions on config files
- Press `Ctrl+R` to reload keybindings after editing
- Check logs for configuration errors

### Application Crashes

- Check `~/.local/share/zigram/zigram.log` for error messages
- Ensure you're using a compatible Zig version (0.15.2+)
- If TDLib download fails, check your internet connection and try rebuilding
