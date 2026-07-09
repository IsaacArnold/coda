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
