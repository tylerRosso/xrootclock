/* SPDX-License-Identifier: ISC */

/* xwire.h - the X11 wire transport shared by xrootclock and its siblings.
 *
 * Everything needed to reach the server without libX11: DISPLAY parsing, the
 * MIT-MAGIC-COOKIE-1 lookup in .Xauthority, the Unix-socket connect, the
 * connection setup, a GetInputFocus round trip (x_sync) and a drain of pending
 * events. It is included textually, so a program stays one translation unit.
 *
 * The one thing it takes from the includer is PROGRAM_NAME, which prefixes its
 * diagnostics. Keep it program-agnostic: requests specific to a program belong
 * next to that program's main(). A copy of this file in another program is
 * expected to stay byte-identical, so a fix here is a fix there.
 *
 * Not every program uses every function, and -Wunused-function would reject
 * the ones it leaves out, so that one warning is off between the push and the
 * pop below and nowhere else. The alternatives were measured: `static inline`
 * silences it too, but changes what clang inlines, so xrootclock's release
 * binary is no longer byte for byte the same; __attribute__((unused)) trips
 * -Wused-but-marked-unused in every program that does call the function. */

#ifndef XWIRE_H
#define XWIRE_H

#ifndef PROGRAM_NAME
#error "xwire.h needs PROGRAM_NAME defined before it is included"
#endif

#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

/* X11 protocol constants (X11/X.h, X11/Xproto.h). */
#define X_PROTOCOL_MAJOR 11
#define X_PROTOCOL_MINOR 0
#define X_OPCODE_GET_INPUT_FOCUS 43
#define X_SETUP_FAILED 0
#define X_SETUP_SUCCESS 1
#define X_ERROR 0
#define X_REPLY 1

/* .Xauthority address families (X11/Xauth.h). */
#define AUTH_FAMILY_LOCAL 256
#define AUTH_FAMILY_WILD 65535

#define AUTH_METHOD "MIT-MAGIC-COOKIE-1"
#define AUTH_METHOD_LEN 18

/* Buffer ceilings. Small enough to keep every buffer on the stack. */
#define MAX_COOKIE 64
#define MAX_AUTH_NUMBER 32
#define MAX_SETUP 65536

/* pad4() is a function, so the wire buffer needs a constant bound of its own. */
#define MAX_SETUP_REQUEST (12 + 20 + MAX_COOKIE)

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"

/* ---------------------------------------------------------------- helpers */

static size_t pad4(size_t length) { return (length + 3u) & ~(size_t)3u; }

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

/* Read one length-prefixed .Xauthority field. Its length is reported whatever
 * it is; its bytes land in BUFFER only when they fit CAPACITY, and are read
 * past otherwise, since a field longer than the buffer meant for it cannot be
 * one this program matches. The file ending inside the field is a truncated
 * record: false. */
static bool read_auth_field(FILE *stream, uint8_t *buffer, size_t capacity, size_t *length)
{
	uint8_t prefix[2];
	size_t  left;

	if (fread(prefix, 1, sizeof prefix, stream) != sizeof prefix)
		return false;

	*length = get16be(prefix);
	left    = *length;

	while (left > 0)
	{
		size_t chunk = (left < capacity) ? left : capacity;

		if (fread(buffer, 1, chunk, stream) != chunk)
			return false;

		left -= chunk;
	}

	return true;
}

/* Pull the MIT-MAGIC-COOKIE-1 entry for this display out of .Xauthority.
 * A missing or unreadable file is not fatal: servers configured without
 * access control accept an empty cookie, so we let the handshake decide. */
static bool load_cookie(const char *number, uint8_t *cookie, uint16_t *cookie_length)
{
	const char *path = getenv("XAUTHORITY");
	char        fallback[PATH_MAX];
	FILE       *stream        = NULL;
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

	if (gethostname(hostname, sizeof hostname) != 0)
		hostname[0] = '\0';

	hostname[sizeof hostname - 1] = '\0';

	/* The file is a flat sequence of records: a family, then four
	 * length-prefixed fields -- address, display number, method name, data.
	 * It is read a record at a time, so its size is no limit; each field has
	 * a bound instead, as large as anything that could match. A field longer
	 * than its bound was read past, not into its buffer, so every length is
	 * compared before the bytes are. The record the file ends inside is
	 * incomplete and ends the walk. */
	for (;;)
	{
		uint8_t  prefix[2];
		uint8_t  address[sizeof hostname];
		uint8_t  entry_number[MAX_AUTH_NUMBER];
		uint8_t  name[AUTH_METHOD_LEN];
		uint8_t  data[MAX_COOKIE];
		size_t   address_length;
		size_t   entry_number_length;
		size_t   name_length;
		size_t   data_length;
		uint16_t family;
		bool     preferred;

		if (fread(prefix, 1, sizeof prefix, stream) != sizeof prefix)
			break;

		family = get16be(prefix);

		if (!read_auth_field(stream, address, sizeof address, &address_length) ||
		    !read_auth_field(stream, entry_number, sizeof entry_number, &entry_number_length) ||
		    !read_auth_field(stream, name, sizeof name, &name_length) ||
		    !read_auth_field(stream, data, sizeof data, &data_length))
			break;

		if (name_length != AUTH_METHOD_LEN || memcmp(name, AUTH_METHOD, AUTH_METHOD_LEN) != 0)
			continue;

		if (entry_number_length > sizeof entry_number || entry_number_length != strlen(number) ||
		    memcmp(entry_number, number, entry_number_length) != 0)
			continue;

		if (family != AUTH_FAMILY_LOCAL && family != AUTH_FAMILY_WILD)
			continue;

		if (data_length == 0 || data_length > MAX_COOKIE)
			continue;

		/* Prefer the entry naming this host, but accept a wildcard one. The
		 * hostname is shorter than the address buffer, so an address of its
		 * length was read in full. */
		preferred = (family == AUTH_FAMILY_LOCAL && hostname[0] != '\0' && address_length == strlen(hostname) &&
		             memcmp(address, hostname, address_length) == 0);

		if (found && !preferred)
			continue;

		memcpy(cookie, data, data_length);
		*cookie_length = (uint16_t)data_length;
		found          = true;

		if (preferred)
			break;
	}

	fclose(stream);

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

/* Block until the server has caught up, the way XSync does it.
 *
 * A request that generates no reply, written just before exiting, is a race the
 * client loses: the server sees the disconnect with the request still unread
 * and discards it. GetInputFocus is the canonical no-op round trip -- it always
 * succeeds and always replies, and because one client's requests are processed
 * in order, its reply proves every earlier request has been applied.
 *
 * Events that arrive ahead of the reply are read and discarded, so a client
 * that selects events loses any that come in during a sync. */
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

/* Read whatever the server has sent, without blocking. An error is reported and
 * ends the drain with false; anything else is discarded, which suits a client
 * that expects no replies and selects no events. */
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

#pragma clang diagnostic pop

#endif /* XWIRE_H */
