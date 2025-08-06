#!/usr/bin/env bash
# ~/.local/bin/bw-auto-auth
# Bitwarden CLI wrapper with automatic authentication

set -e

# Load environment variables if .env exists
if [ -f "$HOME/dotfiles/.env" ]; then
    source "$HOME/dotfiles/.env"
fi

SESSION_FILE="$HOME/.cache/bw-session"
SERVER_URL="${BITWARDEN_SERVER_URL:-https://vault.bitwarden.com}"

# Ensure cache directory exists
mkdir -p "$(dirname "$SESSION_FILE")"

# Function to get password via popup
get_password() {
  local title="$1"
  local prompt="$2"

  # Try zenity first (GUI popup)
  if command -v zenity &>/dev/null && [ -n "$DISPLAY" ]; then
    zenity --password --title="$title" --text="$prompt" 2>/dev/null
  # Fallback to WSL with Windows integration
  elif command -v powershell.exe &>/dev/null; then
    # Use Windows Forms for password input
    powershell.exe -WindowStyle Hidden -Command "
            Add-Type -AssemblyName System.Windows.Forms
            Add-Type -AssemblyName System.Drawing
            \$form = New-Object System.Windows.Forms.Form
            \$form.Text = '$title'
            \$form.Size = New-Object System.Drawing.Size(350,150)
            \$form.StartPosition = 'CenterScreen'
            \$form.FormBorderStyle = 'FixedDialog'
            \$form.MaximizeBox = \$false
            \$form.MinimizeBox = \$false
            \$form.TopMost = \$true
            
            \$label = New-Object System.Windows.Forms.Label
            \$label.Location = New-Object System.Drawing.Point(10,20)
            \$label.Size = New-Object System.Drawing.Size(320,20)
            \$label.Text = '$prompt'
            \$form.Controls.Add(\$label)
            
            \$textBox = New-Object System.Windows.Forms.TextBox
            \$textBox.Location = New-Object System.Drawing.Point(10,50)
            \$textBox.Size = New-Object System.Drawing.Size(300,20)
            \$textBox.UseSystemPasswordChar = \$true
            \$form.Controls.Add(\$textBox)
            
            \$OKButton = New-Object System.Windows.Forms.Button
            \$OKButton.Location = New-Object System.Drawing.Point(75,80)
            \$OKButton.Size = New-Object System.Drawing.Size(75,23)
            \$OKButton.Text = 'OK'
            \$OKButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
            \$form.AcceptButton = \$OKButton
            \$form.Controls.Add(\$OKButton)
            
            \$CancelButton = New-Object System.Windows.Forms.Button
            \$CancelButton.Location = New-Object System.Drawing.Point(150,80)
            \$CancelButton.Size = New-Object System.Drawing.Size(75,23)
            \$CancelButton.Text = 'Cancel'
            \$CancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
            \$form.CancelButton = \$CancelButton
            \$form.Controls.Add(\$CancelButton)
            
            \$textBox.Add_KeyDown({
                if (\$_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
                    \$form.DialogResult = [System.Windows.Forms.DialogResult]::OK
                }
            })
            
            \$form.Add_Shown({
                \$textBox.Select()
                \$form.Activate()
            })
            
            \$result = \$form.ShowDialog()
            
            if (\$result -eq [System.Windows.Forms.DialogResult]::OK) {
                \$textBox.Text
            } else {
                exit 1
            }
        " 2>/dev/null
  else
    # Final fallback to terminal input
    echo "Enter password for $title:" >&2
    read -s password
    echo "$password"
  fi
}

# Function to check if session is valid
is_session_valid() {
  if [ -f "$SESSION_FILE" ]; then
    local session=$(cat "$SESSION_FILE" 2>/dev/null)
    if [ -n "$session" ]; then
      BW_SESSION="$session" bw status 2>/dev/null | grep -q "unlocked"
      return $?
    fi
  fi
  return 1
}

# Function to authenticate
authenticate() {
  local status=$(bw status 2>/dev/null | jq -r '.status' 2>/dev/null || echo "unknown")

  case "$status" in
  "unauthenticated")
    echo "🔐 Logging in to Bitwarden..." >&2
    local email=$(get_password "Bitwarden Login" "Enter your email address:")
    [ -z "$email" ] && {
      echo "❌ Email required" >&2
      exit 1
    }

    local password=$(get_password "Bitwarden Login" "Enter your master password:")
    [ -z "$password" ] && {
      echo "❌ Password required" >&2
      exit 1
    }

    echo "$password" | bw login "$email" --server "$SERVER_URL" --raw >/dev/null
    status="locked"
    ;;
  "locked")
    echo "🔓 Unlocking Bitwarden vault..." >&2
    ;;
  "unlocked")
    echo "✅ Bitwarden vault already unlocked" >&2
    return 0
    ;;
  esac

  if [ "$status" = "locked" ]; then
    local password=$(get_password "Bitwarden Unlock" "Enter your master password to unlock vault:")
    [ -z "$password" ] && {
      echo "❌ Password required" >&2
      exit 1
    }

    local session=$(echo "$password" | bw unlock --raw 2>/dev/null)
    if [ -n "$session" ]; then
      echo "$session" >"$SESSION_FILE"
      chmod 600 "$SESSION_FILE"
      export BW_SESSION="$session"
    else
      echo "❌ Failed to unlock vault" >&2
      exit 1
    fi
  fi
}

# Main execution
main() {
  # Check if we have a valid session
  if ! is_session_valid; then
    authenticate
  else
    export BW_SESSION=$(cat "$SESSION_FILE")
  fi

  # Execute the bw command with session
  BW_SESSION=$(cat "$SESSION_FILE" 2>/dev/null) bw "$@"
}

# Handle the case where no arguments are provided
if [ $# -eq 0 ]; then
  echo "Usage: bw-auto-auth <bw-command> [args...]" >&2
  echo "Example: bw-auto-auth get password 'OpenAI API Key'" >&2
  exit 1
fi

main "$@"
