# Coda shell integration — keep shell history out of the app bundle.
#
# Stock macOS /etc/zshrc does `HISTFILE=${ZDOTDIR:-$HOME}/.zsh_history`, and it runs after our
# .zshenv/.zprofile but before this file. While the wrapper is active ZDOTDIR is Coda's bundle, so
# an uncorrected shell saves the user's history INSIDE Coda.app — wiped by every update, and a
# write into a notarized bundle. Point it back at their own dotfile directory, which is where it
# would have gone without us.
#
# Guarded on the exact bundle-relative path so a HISTFILE the user set deliberately (in .zshenv,
# which ran earlier) is left alone; doing this before chaining .zshrc below means anything they set
# there still wins.
if [[ $HISTFILE == $ZDOTDIR/.zsh_history ]]; then
	HISTFILE=${CODA_USER_ZDOTDIR:-$HOME}/.zsh_history
fi

# Coda shell integration — chain the user's .zshrc first.
if [[ -f ${CODA_USER_ZDOTDIR:-$HOME}/.zshrc ]]; then
	CODA_ZDOTDIR=$ZDOTDIR
	ZDOTDIR=${CODA_USER_ZDOTDIR:-$HOME}
	. "${CODA_USER_ZDOTDIR:-$HOME}/.zshrc"
	CODA_USER_ZDOTDIR=$ZDOTDIR
	ZDOTDIR=$CODA_ZDOTDIR
fi

# OSC 133 prompt markers for Coda's completion engine (idempotent — guard against
# double-install if this file is sourced twice in one shell).
if [[ -z ${CODA_OSC133_INSTALLED-} ]]; then
	CODA_OSC133_INSTALLED=1

	__coda_osc133_precmd() {
		local __coda_exit=$?
		# D;<code> closes the PREVIOUS command; skip before the first command ran.
		if [[ -n ${CODA_OSC133_RAN-} ]]; then
			printf '\033]133;D;%s\007' "$__coda_exit"
		fi
		printf '\033]133;A\007'   # prompt-start
	}
	__coda_osc133_preexec() {
		CODA_OSC133_RAN=1
		printf '\033]133;C\007'   # pre-exec: a command is about to run
	}
	# B = command-start; append to PS1 (zero-width via %{...%}) so it prints at the
	# END of the prompt, marking where typed input begins.
	PS1="${PS1}"$'%{\033]133;B\007%}'

	autoload -Uz add-zsh-hook
	add-zsh-hook precmd  __coda_osc133_precmd
	add-zsh-hook preexec __coda_osc133_preexec
fi

# OSC 7 current-directory reports, so ⌘ + click resolves paths relative to wherever the shell
# has cd'd, not just the worktree root (#84). Sent on every prompt (not only on cd) so the first
# prompt, subshells and `exec zsh` report too. The path is percent-encoded byte by byte (LC_ALL=C
# makes ${#PWD} and $PWD[i] work on bytes), so spaces and non-ASCII survive the file:// URL.
if [[ -z ${CODA_OSC7_INSTALLED-} ]]; then
	CODA_OSC7_INSTALLED=1

	__coda_osc7_precmd() {
		emulate -L zsh
		local LC_ALL=C ch hex encoded= i
		for (( i = 1; i <= ${#PWD}; i++ )); do
			ch=$PWD[i]
			if [[ $ch == [A-Za-z0-9/._~-] ]]; then
				encoded+=$ch
			else
				printf -v hex '%%%02X' "'$ch"
				encoded+=$hex
			fi
		done
		printf '\033]7;file://%s%s\007' "${HOST}" "$encoded"
	}

	autoload -Uz add-zsh-hook
	add-zsh-hook precmd __coda_osc7_precmd
fi
