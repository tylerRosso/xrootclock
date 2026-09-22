/* SPDX-License-Identifier: ISC */

/* xrootclock - periodically write a strftime(3) clock into the X11 root
 * window's WM_NAME property, the way dwm and similar bars read their status.
 *
 * The X11 wire protocol is spoken directly over the display's Unix socket, so
 * the program links against nothing but libc. In the steady state each update
 * costs one write(2), one non-blocking recv(2) and one clock_nanosleep(2); the
 * clock itself is read through the vDSO and costs no syscall at all.
 */

/* xwire.h prefixes its diagnostics with PROGRAM_NAME, so it must be defined
 * before the includes: clang-format keeps quoted includes ahead of system ones. */
#define PROGRAM_NAME "xrootclock"

#include "xwire.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

/* The user-visible defaults. */
#define DEFAULT_FORMAT " %a %m%d%y %I%M "
#define DEFAULT_INTERVAL 60
#define MAX_INTERVAL 86400

/* X11 protocol constants (X11/X.h, X11/Xatom.h, X11/Xproto.h). The transport's
 * own live in xwire.h. */
#define X_OPCODE_CHANGE_PROP 18
#define X_PROP_MODE_REPLACE 0
#define X_ATOM_STRING 31
#define X_ATOM_WM_NAME 39

/* Buffer ceiling. Generous for a status line, small enough to keep the buffer
 * on the stack. */
#define MAX_STATUS 512

/* pad4() is a function, so the wire buffer needs a constant bound of its own.
 * MAX_STATUS is already a multiple of four. */
#define MAX_PROP_REQUEST (24 + MAX_STATUS)

static volatile sig_atomic_t keep_running = 1;

static void on_signal(int signal_number)
{
	(void)signal_number;

	keep_running = 0;
}

/* ---------------------------------------------------------------- helpers */

/* Upper-case the ASCII letters in place, and nothing else.
 *
 * Bytes >= 0x80 pass through untouched, so a UTF-8 sequence survives intact:
 * every byte of one is >= 0x80 and therefore outside 'a'..'z'. (char is signed
 * on this target, which makes those bytes negative and the range test false
 * either way.)
 *
 * Spelled out rather than calling toupper(3) so that guarantee belongs to this
 * code rather than to the libc underneath it. musl's toupper happens to be
 * ASCII-only and locale-independent, and this program never calls setlocale, so
 * today the two agree -- but that is a coincidence of the toolchain, not a
 * property worth depending on.
 *
 * It exists because musl's strftime has no %^, the GNU upper-case modifier, so
 * there is otherwise no way to ask for "WED" instead of "Wed". */
static void upper_ascii(char *text, size_t length)
{
	for (size_t i = 0; i < length; i++)
	{
		if (text[i] >= 'a' && text[i] <= 'z')
			text[i] = (char)(text[i] - ('a' - 'A'));
	}
}

/* ---------------------------------------------------------------- request */

/* ChangeProperty(Replace, root, WM_NAME, STRING, 8, text). Generates no reply;
 * a malformed request comes back later as an asynchronous error event. */
static bool x_set_root_name(int file_descriptor, uint32_t root_window, const char *text, size_t length)
{
	uint8_t request[MAX_PROP_REQUEST];
	size_t  padded = pad4(length);

	/* The only caller clears this by one byte, since strftime cannot return more
	 * than MAX_STATUS - 1. Check anyway rather than rely on that margin. */
	if (length > MAX_STATUS)
	{
		errno = EMSGSIZE;

		return false;
	}

	memset(request, 0, sizeof request);

	request[0] = X_OPCODE_CHANGE_PROP;
	request[1] = X_PROP_MODE_REPLACE;
	put16(request + 2, (uint16_t)((24u + padded) / 4u));
	put32(request + 4, root_window);
	put32(request + 8, X_ATOM_WM_NAME);
	put32(request + 12, X_ATOM_STRING);
	request[16] = 8; /* format: 8 bits per item */
	put32(request + 20, (uint32_t)length);

	memcpy(request + 24, text, length);

	return write_all(file_descriptor, request, 24u + padded);
}

/* ------------------------------------------------------------------- main */

static void usage(FILE *stream)
{
	fprintf(stream,
	        "Usage: " PROGRAM_NAME " [-i SECONDS] [-1] [-u] [FORMAT]\n"
	        "\n"
	        "Write a strftime(3) clock into the X11 root window's WM_NAME property.\n"
	        "\n"
	        "  -i SECONDS  update interval, aligned to the wall clock (default %d)\n"
	        "  -1          update once and exit\n"
	        "  -u          upper-case the ASCII letters in the result\n"
	        "  -h          show this help\n"
	        "\n"
	        "FORMAT defaults to '%s'.\n",
	        DEFAULT_INTERVAL, DEFAULT_FORMAT);
}

int main(int argc, char *argv[])
{
	const char      *format   = DEFAULT_FORMAT;
	long             interval = DEFAULT_INTERVAL;
	bool             once     = false;
	bool             upper    = false;
	char             socket_path[PATH_MAX];
	char             display_number[16];
	uint8_t          cookie[MAX_COOKIE];
	uint16_t         cookie_length   = 0;
	uint32_t         root_window     = 0;
	int              file_descriptor = -1;
	bool             ok              = true;
	int              index           = 1;
	struct sigaction action;

	while (index < argc && argv[index][0] == '-' && argv[index][1] != '\0')
	{
		const char *option = argv[index];

		if (strcmp(option, "-h") == 0 || strcmp(option, "--help") == 0)
		{
			usage(stdout);

			return EXIT_SUCCESS;
		}

		/* Standard end-of-options marker, so a FORMAT may begin with '-'. */
		if (strcmp(option, "--") == 0)
		{
			index++;

			break;
		}

		if (strcmp(option, "-1") == 0 || strcmp(option, "--once") == 0)
		{
			once = true;
			index++;

			continue;
		}

		if (strcmp(option, "-u") == 0 || strcmp(option, "--upper") == 0)
		{
			upper = true;
			index++;

			continue;
		}

		if (strcmp(option, "-i") == 0 || strcmp(option, "--interval") == 0)
		{
			char *end = NULL;

			if (index + 1 >= argc)
			{
				fprintf(stderr, PROGRAM_NAME ": '%s' needs a value.\n", option);

				return EXIT_FAILURE;
			}

			errno    = 0;
			interval = strtol(argv[index + 1], &end, 10);

			if (errno != 0 || end == argv[index + 1] || *end != '\0' || interval < 1 || interval > MAX_INTERVAL)
			{
				fprintf(stderr, PROGRAM_NAME ": interval must be between 1 and %d seconds.\n", MAX_INTERVAL);

				return EXIT_FAILURE;
			}

			index += 2;

			continue;
		}

		fprintf(stderr, PROGRAM_NAME ": unknown option '%s'.\n", option);
		usage(stderr);

		return EXIT_FAILURE;
	}

	if (index < argc)
	{
		format = argv[index];
		index++;
	}

	if (index < argc)
	{
		fprintf(stderr, PROGRAM_NAME ": unexpected argument '%s'.\n", argv[index]);

		return EXIT_FAILURE;
	}

	if (!parse_display(getenv("DISPLAY"), socket_path, sizeof socket_path, display_number, sizeof display_number))
		return EXIT_FAILURE;

	/* An absent cookie is fine; an access-controlled server will say no. */
	(void)load_cookie(display_number, cookie, &cookie_length);

	file_descriptor = x_connect(socket_path);

	if (file_descriptor < 0)
		return EXIT_FAILURE;

	if (!x_handshake(file_descriptor, cookie, cookie_length, &root_window))
	{
		close(file_descriptor);

		return EXIT_FAILURE;
	}

	/* Deliberately not SA_RESTART: a signal must break the sleep. */
	memset(&action, 0, sizeof action);
	action.sa_handler = on_signal;
	sigemptyset(&action.sa_mask);
	sigaction(SIGINT, &action, NULL);
	sigaction(SIGTERM, &action, NULL);
	sigaction(SIGHUP, &action, NULL);

	/* A dead X server must surface as a write error, not as a fatal signal. */
	memset(&action, 0, sizeof action);
	action.sa_handler = SIG_IGN;
	sigemptyset(&action.sa_mask);
	sigaction(SIGPIPE, &action, NULL);

	while (keep_running)
	{
		struct timespec now;
		struct timespec deadline;
		struct tm       broken_down;
		char            status[MAX_STATUS];
		size_t          status_length;

		if (clock_gettime(CLOCK_REALTIME, &now) != 0)
		{
			perror(PROGRAM_NAME ": clock_gettime");
			ok = false;

			break;
		}

		if (localtime_r(&now.tv_sec, &broken_down) == NULL)
		{
			fprintf(stderr, PROGRAM_NAME ": cannot convert the current time to local time.\n");
			ok = false;

			break;
		}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wformat-nonliteral"
		status_length = strftime(status, sizeof status, format, &broken_down);
#pragma clang diagnostic pop

		if (upper)
			upper_ascii(status, status_length);

		/* strftime returns 0 for two different reasons -- an unsupported
		 * conversion, and a result that does not fit -- and in both cases it
		 * discards the WHOLE output, not just the offending part. Writing that
		 * would silently blank the status line, so treat it as fatal. An empty
		 * format is the one legitimate way to get 0.
		 *
		 * Retry into a larger buffer to tell the two causes apart: guessing from
		 * strlen(format) does not work, because it is the OUTPUT that overflows
		 * -- "%A" repeated 80 times is only 160 bytes of format. */
		if (status_length == 0 && format[0] != '\0')
		{
			char probe[MAX_STATUS * 4];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wformat-nonliteral"
			bool too_long = strftime(probe, sizeof probe, format, &broken_down) > 0;
#pragma clang diagnostic pop

			if (too_long)
				fprintf(stderr, PROGRAM_NAME ": format '%s' expands to more than %d bytes.\n", format, MAX_STATUS - 1);
			else
				fprintf(stderr,
				        PROGRAM_NAME ": format '%s' produced no output.\n"
				                     "musl's strftime does not support the GNU extensions: %%^ (upper case),\n"
				                     "%%# (swap case), %%-, %%_, %%0 (padding) or %%q (quarter).\n"
				                     "For upper case use the -u option instead of %%^.\n",
				        format);

			ok = false;

			break;
		}

		if (!x_set_root_name(file_descriptor, root_window, status, status_length))
		{
			fprintf(stderr, PROGRAM_NAME ": cannot update the root window: %s\n", strerror(errno));
			ok = false;

			break;
		}

		if (!x_drain(file_descriptor))
		{
			ok = false;

			break;
		}

		if (once)
			break;

		/* Absolute deadlines on the wall clock: the wakeups stay pinned to the
		 * boundary instead of drifting by one round trip per iteration. */
		deadline.tv_sec  = ((now.tv_sec / interval) + 1) * interval;
		deadline.tv_nsec = 0;

		while (keep_running)
		{
			int result = clock_nanosleep(CLOCK_REALTIME, TIMER_ABSTIME, &deadline, NULL);

			if (result == 0)
				break;

			if (result != EINTR)
			{
				errno = result;
				perror(PROGRAM_NAME ": clock_nanosleep");
				keep_running = 0;
				ok           = false;

				break;
			}
		}
	}

	/* The last update is still only queued: without this round trip the server
	 * would see the disconnect first and drop it. */
	if (ok && !x_sync(file_descriptor))
		ok = false;

	close(file_descriptor);

	return ok ? EXIT_SUCCESS : EXIT_FAILURE;
}
