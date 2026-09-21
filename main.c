/* SPDX-License-Identifier: ISC */

/* xrootclock - periodically write a strftime(3) clock into the X11 root
 * window's WM_NAME property, the way dwm and similar bars read their status.
 *
 * The X11 wire protocol is spoken directly over the display's Unix socket, so
 * the program links against nothing but libc. In the steady state each update
 * costs one write(2), one non-blocking recv(2) and one clock_nanosleep(2); the
 * clock itself is read through the vDSO and costs no syscall at all.
 */

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

#define PROGRAM_NAME "xrootclock"

/* The user-visible defaults. */
#define DEFAULT_FORMAT " %a %m%d%y %I%M "
#define DEFAULT_INTERVAL 60
#define MAX_INTERVAL 86400

/* X11 protocol constants (X11/X.h, X11/Xatom.h, X11/Xproto.h). */
#define X_PROTOCOL_MAJOR 11
#define X_PROTOCOL_MINOR 0
#define X_OPCODE_CHANGE_PROP 18
#define X_OPCODE_GET_INPUT_FOCUS 43
#define X_PROP_MODE_REPLACE 0
#define X_ATOM_STRING 31
#define X_ATOM_WM_NAME 39
#define X_SETUP_FAILED 0
#define X_SETUP_SUCCESS 1
#define X_ERROR 0
#define X_REPLY 1

/* .Xauthority address families (X11/Xauth.h). */
#define AUTH_FAMILY_LOCAL 256
#define AUTH_FAMILY_WILD 65535

#define AUTH_METHOD "MIT-MAGIC-COOKIE-1"
#define AUTH_METHOD_LEN 18

/* Buffer ceilings. Generous for a status line, small enough to keep every
 * buffer on the stack. */
#define MAX_STATUS 512
#define MAX_COOKIE 64
#define MAX_AUTHFILE 65536
#define MAX_SETUP 65536

/* pad4() is a function, so the wire buffers need constant bounds of their own.
 * MAX_STATUS is already a multiple of four. */
#define MAX_SETUP_REQUEST (12 + 20 + MAX_COOKIE)
#define MAX_PROP_REQUEST (24 + MAX_STATUS)

static volatile sig_atomic_t keep_running = 1;

static void on_signal(int signal_number)
{
	(void)signal_number;

	keep_running = 0;
}

/* ---------------------------------------------------------------- helpers */

static size_t pad4(size_t length) { return (length + 3u) & ~(size_t)3u; }

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

/* The connection is opened little-endian, so every protocol field is too. */
static void put16(uint8_t *buffer, uint16_t value)
{
	buffer[0] = (uint8_t)(value & 0xffu);
	buffer[1] = (uint8_t)((value >> 8) & 0xffu);
}

static void put32(uint8_t *buffer, uint32_t value)
{
	buffer[0] = (uint8_t)(value & 0xffu);
	buffer[1] = (uint8_t)((value >> 8) & 0xffu);
	buffer[2] = (uint8_t)((value >> 16) & 0xffu);
	buffer[3] = (uint8_t)((value >> 24) & 0xffu);
}

static uint16_t get16(const uint8_t *buffer)
{
	return (uint16_t)((uint16_t)buffer[0] | (uint16_t)((uint16_t)buffer[1] << 8));
}

static uint32_t get32(const uint8_t *buffer)
{
	return (uint32_t)buffer[0] | ((uint32_t)buffer[1] << 8) | ((uint32_t)buffer[2] << 16) | ((uint32_t)buffer[3] << 24);
}

/* .Xauthority is network byte order, unlike the protocol itself. */
static uint16_t get16be(const uint8_t *buffer)
{
	return (uint16_t)((uint16_t)((uint16_t)buffer[0] << 8) | (uint16_t)buffer[1]);
}

static bool write_all(int file_descriptor, const uint8_t *buffer, size_t length)
{
	size_t written = 0;

	while (written < length)
	{
		ssize_t chunk = write(file_descriptor, buffer + written, length - written);

		if (chunk < 0)
		{
			if (errno == EINTR)
				continue;

			return false;
		}

		written += (size_t)chunk;
	}

	return true;
}

static bool read_all(int file_descriptor, uint8_t *buffer, size_t length)
{
	size_t have = 0;

	while (have < length)
	{
		ssize_t chunk = read(file_descriptor, buffer + have, length - have);

		if (chunk < 0)
		{
			if (errno == EINTR)
				continue;

			return false;
		}

		if (chunk == 0)
		{
			errno = ECONNRESET;

			return false;
		}

		have += (size_t)chunk;
	}

	return true;
}

/* ---------------------------------------------------------------- display */

/* Split DISPLAY into the Unix socket path and the display number. Only local
 * displays are supported; a TCP display would need a different transport and
 * defeats the point of the program. */
static bool parse_display(const char *display, char *path, size_t path_size, char *number, size_t number_size)
{
	const char *colon = NULL;
	const char *dot   = NULL;
	size_t      host_length;
	size_t      number_length;
	int         written;

	if (display == NULL || display[0] == '\0')
	{
		fprintf(stderr, PROGRAM_NAME ": DISPLAY is not set.\n");

		return false;
	}

	colon = strrchr(display, ':');

	if (colon == NULL)
	{
		fprintf(stderr, PROGRAM_NAME ": malformed DISPLAY '%s', expected something like ':0'.\n", display);

		return false;
	}

	host_length = (size_t)(colon - display);

	if (host_length != 0 && !(host_length == 4 && strncmp(display, "unix", 4) == 0))
	{
		fprintf(stderr, PROGRAM_NAME ": only local displays are supported, got '%s'.\n", display);

		return false;
	}

	dot           = strchr(colon + 1, '.');
	number_length = (dot != NULL) ? (size_t)(dot - (colon + 1)) : strlen(colon + 1);

	if (number_length == 0 || number_length >= number_size)
	{
		fprintf(stderr, PROGRAM_NAME ": malformed display number in '%s'.\n", display);

		return false;
	}

	for (size_t i = 0; i < number_length; i++)
	{
		if (colon[1 + i] < '0' || colon[1 + i] > '9')
		{
			fprintf(stderr, PROGRAM_NAME ": malformed display number in '%s'.\n", display);

			return false;
		}
	}

	memcpy(number, colon + 1, number_length);
	number[number_length] = '\0';

	written = snprintf(path, path_size, "/tmp/.X11-unix/X%s", number);

	if (written < 0 || (size_t)written >= path_size)
	{
		fprintf(stderr, PROGRAM_NAME ": socket path for display '%s' is too long.\n", display);

		return false;
	}

	return true;
}

/* ------------------------------------------------------------------- auth */

/* Pull the MIT-MAGIC-COOKIE-1 entry for this display out of .Xauthority.
 * A missing or unreadable file is not fatal: servers configured without
 * access control accept an empty cookie, so we let the handshake decide. */
static bool load_cookie(const char *number, uint8_t *cookie, uint16_t *cookie_length)
{
	static uint8_t contents[MAX_AUTHFILE];

	const char *path = getenv("XAUTHORITY");
	char        fallback[PATH_MAX];
	FILE       *stream        = NULL;
	size_t      total         = 0;
	size_t      offset        = 0;
	char        hostname[256] = "";
	bool        found         = false;
	int         written;

	*cookie_length = 0;

	if (path == NULL || path[0] == '\0')
	{
		const char *home = getenv("HOME");

		if (home == NULL || home[0] == '\0')
			return false;

		written = snprintf(fallback, sizeof fallback, "%s/.Xauthority", home);

		if (written < 0 || (size_t)written >= sizeof fallback)
			return false;

		path = fallback;
	}

	stream = fopen(path, "rb");

	if (stream == NULL)
		return false;

	total = fread(contents, 1, sizeof contents, stream);
	fclose(stream);

	if (gethostname(hostname, sizeof hostname) != 0)
		hostname[0] = '\0';

	hostname[sizeof hostname - 1] = '\0';

	/* family, then four length-prefixed fields: address, number, name, data. */
	while (offset + 2 <= total)
	{
		uint16_t    family = get16be(contents + offset);
		const char *field[4];
		uint16_t    field_length[4];
		bool        truncated = false;
		bool        preferred;

		offset += 2;

		for (size_t i = 0; i < 4; i++)
		{
			if (offset + 2 > total)
			{
				truncated = true;

				break;
			}

			field_length[i] = get16be(contents + offset);
			offset += 2;

			if (offset + field_length[i] > total)
			{
				truncated = true;

				break;
			}

			field[i] = (const char *)(contents + offset);
			offset += field_length[i];
		}

		if (truncated)
			break;

		if (field_length[2] != AUTH_METHOD_LEN || memcmp(field[2], AUTH_METHOD, AUTH_METHOD_LEN) != 0)
			continue;

		if (field_length[1] != strlen(number) || memcmp(field[1], number, field_length[1]) != 0)
			continue;

		if (family != AUTH_FAMILY_LOCAL && family != AUTH_FAMILY_WILD)
			continue;

		if (field_length[3] == 0 || field_length[3] > MAX_COOKIE)
			continue;

		/* Prefer the entry naming this host, but accept a wildcard one. */
		preferred = (family == AUTH_FAMILY_LOCAL && hostname[0] != '\0' && field_length[0] == strlen(hostname) &&
		             memcmp(field[0], hostname, field_length[0]) == 0);

		if (found && !preferred)
			continue;

		memcpy(cookie, field[3], field_length[3]);
		*cookie_length = field_length[3];
		found          = true;

		if (preferred)
			break;
	}

	return found;
}

/* ------------------------------------------------------------- connection */

static int x_connect(const char *path)
{
	union
	{
		struct sockaddr    any;
		struct sockaddr_un local;
	} address;

	size_t length          = strlen(path);
	int    file_descriptor = -1;

	if (length >= sizeof address.local.sun_path)
	{
		fprintf(stderr, PROGRAM_NAME ": socket path '%s' is too long.\n", path);

		return -1;
	}

	memset(&address, 0, sizeof address);
	address.local.sun_family = AF_UNIX;
	memcpy(address.local.sun_path, path, length + 1);

	file_descriptor = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);

	if (file_descriptor < 0)
	{
		perror(PROGRAM_NAME ": socket");

		return -1;
	}

	if (connect(file_descriptor, &address.any, (socklen_t)sizeof address.local) != 0)
	{
		fprintf(stderr, PROGRAM_NAME ": cannot connect to '%s': %s\n", path, strerror(errno));
		close(file_descriptor);

		return -1;
	}

	return file_descriptor;
}

/* Perform the connection setup and return the first screen's root window. */
static bool x_handshake(int file_descriptor, const uint8_t *cookie, uint16_t cookie_length, uint32_t *root_window)
{
	static uint8_t reply[MAX_SETUP];

	uint8_t  request[MAX_SETUP_REQUEST];
	size_t   request_length = 12;
	uint8_t  prefix[8];
	uint16_t additional;
	size_t   additional_bytes;
	uint16_t vendor_length;
	uint8_t  format_count;
	uint8_t  screen_count;
	size_t   screen_offset;

	memset(request, 0, sizeof request);

	request[0] = (uint8_t)'l'; /* little-endian client */
	put16(request + 2, X_PROTOCOL_MAJOR);
	put16(request + 4, X_PROTOCOL_MINOR);

	if (cookie_length > 0)
	{
		put16(request + 6, AUTH_METHOD_LEN);
		put16(request + 8, cookie_length);

		memcpy(request + request_length, AUTH_METHOD, AUTH_METHOD_LEN);
		request_length += pad4(AUTH_METHOD_LEN);

		memcpy(request + request_length, cookie, cookie_length);
		request_length += pad4(cookie_length);
	}

	if (!write_all(file_descriptor, request, request_length))
	{
		fprintf(stderr, PROGRAM_NAME ": cannot send the connection setup: %s\n", strerror(errno));

		return false;
	}

	if (!read_all(file_descriptor, prefix, sizeof prefix))
	{
		fprintf(stderr, PROGRAM_NAME ": cannot read the connection setup reply: %s\n", strerror(errno));

		return false;
	}

	additional       = get16(prefix + 6);
	additional_bytes = (size_t)additional * 4u;

	if (additional_bytes > sizeof reply)
	{
		fprintf(stderr, PROGRAM_NAME ": connection setup reply is too large (%zu bytes).\n", additional_bytes);

		return false;
	}

	if (!read_all(file_descriptor, reply, additional_bytes))
	{
		fprintf(stderr, PROGRAM_NAME ": cannot read the connection setup reply: %s\n", strerror(errno));

		return false;
	}

	if (prefix[0] != X_SETUP_SUCCESS)
	{
		size_t reason_length = prefix[1];

		if (reason_length > additional_bytes)
			reason_length = additional_bytes;

		if (prefix[0] == X_SETUP_FAILED && reason_length > 0)
			fprintf(stderr, PROGRAM_NAME ": the X server refused the connection: %.*s\n", (int)reason_length,
			        (const char *)reply);
		else
			fprintf(stderr, PROGRAM_NAME ": the X server refused the connection (code %u).\n", prefix[0]);

		return false;
	}

	/* release(4) ridBase(4) ridMask(4) motionBufferSize(4) nbytesVendor(2)
	 * maxRequestSize(2) numRoots(1) numFormats(1) ... fixed part is 32 bytes,
	 * then the vendor string, then the pixmap formats, then the screens. */
	if (additional_bytes < 32)
	{
		fprintf(stderr, PROGRAM_NAME ": truncated connection setup reply.\n");

		return false;
	}

	vendor_length = get16(reply + 16);
	screen_count  = reply[20];
	format_count  = reply[21];

	if (screen_count == 0)
	{
		fprintf(stderr, PROGRAM_NAME ": the X server reported no screens.\n");

		return false;
	}

	screen_offset = 32u + pad4(vendor_length) + ((size_t)format_count * 8u);

	if (screen_offset + 4u > additional_bytes)
	{
		fprintf(stderr, PROGRAM_NAME ": truncated connection setup reply.\n");

		return false;
	}

	*root_window = get32(reply + screen_offset);

	return true;
}

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

/* Block until the server has caught up, the way XSync does it.
 *
 * ChangeProperty generates no reply, so writing it and exiting immediately is a
 * race the client loses: the server sees the disconnect with the request still
 * unread and discards it, and the property is never set. GetInputFocus is the
 * canonical no-op round trip -- it always succeeds and always replies, and
 * because one client's requests are processed in order, its reply proves every
 * earlier request has been applied.
 *
 * Only needed before exiting. Inside the update loop the sleep is round trips
 * longer than the server needs, so the steady state stays at three syscalls. */
static bool x_sync(int file_descriptor)
{
	uint8_t request[4];
	uint8_t packet[32];

	memset(request, 0, sizeof request);

	request[0] = X_OPCODE_GET_INPUT_FOCUS;
	put16(request + 2, 1); /* length, in 4-byte units */

	if (!write_all(file_descriptor, request, sizeof request))
	{
		fprintf(stderr, PROGRAM_NAME ": cannot flush the connection: %s\n", strerror(errno));

		return false;
	}

	/* Events may arrive ahead of the reply; skip past them. */
	for (;;)
	{
		if (!read_all(file_descriptor, packet, sizeof packet))
		{
			fprintf(stderr, PROGRAM_NAME ": the X server closed the connection: %s\n", strerror(errno));

			return false;
		}

		if (packet[0] == X_ERROR)
		{
			fprintf(stderr, PROGRAM_NAME ": the X server returned error code %u.\n", packet[1]);

			return false;
		}

		if (packet[0] == X_REPLY)
			return true;
	}
}

/* Drain whatever the server pushed back. Nothing is expected, so anything that
 * arrives is an error event worth reporting rather than silently discarding. */
static bool x_drain(int file_descriptor)
{
	uint8_t event[32];

	for (;;)
	{
		ssize_t got = recv(file_descriptor, event, sizeof event, MSG_DONTWAIT);

		if (got < 0)
		{
			if (errno == EINTR)
				continue;

			if (errno == EAGAIN || errno == EWOULDBLOCK)
				return true;

			fprintf(stderr, PROGRAM_NAME ": lost the connection to the X server: %s\n", strerror(errno));

			return false;
		}

		if (got == 0)
		{
			fprintf(stderr, PROGRAM_NAME ": the X server closed the connection.\n");

			return false;
		}

		/* A packet split across reads would otherwise have its tail misread as a
		 * fresh one. Rare on a local socket, cheap to rule out: the extra read
		 * only happens when the first one came up short. */
		if ((size_t)got < sizeof event && !read_all(file_descriptor, event + got, sizeof event - (size_t)got))
		{
			fprintf(stderr, PROGRAM_NAME ": lost the connection to the X server: %s\n", strerror(errno));

			return false;
		}

		if (event[0] == X_ERROR)
		{
			fprintf(stderr, PROGRAM_NAME ": the X server returned error code %u.\n", event[1]);

			return false;
		}
	}
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
