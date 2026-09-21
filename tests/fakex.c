/* SPDX-License-Identifier: ISC */

/* fakex - a fake X server for the xrootclock test suite.
 *
 * Binds /tmp/.X11-unix/X<display>, answers the connection setup, replies to
 * GetInputFocus, and logs every request it receives to stdout so a shell test
 * can assert against it. It never touches a real display.
 *
 * Log lines use RAW protocol numbers on purpose. A test that asserted against
 * xrootclock's own X_ATOM_WM_NAME macro would compare the program to itself and
 * pass even if the constant were wrong, so tests match the literal 18/31/39/43
 * from the X11 spec instead.
 *
 *   usage: fakex DISPLAYNUM [MODE]
 *
 *   MODE   ok       (default) normal service
 *          refuse   reject the connection setup with a reason string
 *          error    accept, but answer ChangeProperty with an X error
 *          split    send every reply in two writes, to exercise short reads
 *          mute     accept, but never reply to GetInputFocus
 *
 * Log lines:
 *   LISTENING <path>
 *   SETUP authname=<len> authdata=<len>
 *   REQUEST opcode=<n> length=<n>
 *   CHANGEPROPERTY mode=<n> window=0x<hex> property=<n> type=<n> format=<n> \
 *                  units=<n> data=<text>
 *   GETINPUTFOCUS
 *   DISCONNECT
 */

#include <errno.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define FAKE_ROOT_WINDOW 0x000002a5u
#define MAX_REQUEST 65536

enum mode
{
	MODE_OK,
	MODE_REFUSE,
	MODE_ERROR,
	MODE_SPLIT,
	MODE_MUTE
};

static volatile sig_atomic_t running = 1;
static enum mode             server_mode;
static char                  socket_path[108];
static uint16_t              sequence;

static void on_signal(int signal_number)
{
	(void)signal_number;

	running = 0;
}

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

static size_t pad4(size_t length) { return (length + 3u) & ~(size_t)3u; }

static bool read_all(int file_descriptor, uint8_t *buffer, size_t length)
{
	size_t have = 0;

	while (have < length)
	{
		ssize_t chunk = read(file_descriptor, buffer + have, length - have);

		if (chunk < 0 && errno == EINTR)
			continue;

		if (chunk <= 0)
			return false;

		have += (size_t)chunk;
	}

	return true;
}

/* In split mode every reply goes out as two writes, so the client is forced to
 * cope with a packet that does not arrive all at once. */
static bool write_all(int file_descriptor, const uint8_t *buffer, size_t length)
{
	size_t written = 0;
	size_t first   = (server_mode == MODE_SPLIT && length > 1) ? length / 2 : length;

	while (written < length)
	{
		size_t  want  = (written < first) ? first - written : length - written;
		ssize_t chunk = write(file_descriptor, buffer + written, want);

		if (chunk < 0 && errno == EINTR)
			continue;

		if (chunk < 0)
			return false;

		written += (size_t)chunk;
	}

	return true;
}

/* Minimal but structurally valid setup reply: one screen, one pixmap format,
 * a short vendor string. 88 bytes of additional data. */
static bool send_setup_success(int file_descriptor)
{
	uint8_t prefix[8];
	uint8_t body[88];

	memset(prefix, 0, sizeof prefix);
	memset(body, 0, sizeof body);

	prefix[0] = 1; /* success */
	put16(prefix + 2, 11);
	put16(prefix + 4, 0);
	put16(prefix + 6, (uint16_t)(sizeof body / 4));

	put32(body + 0, 1);           /* release */
	put32(body + 4, 0x00400000u); /* resource-id base */
	put32(body + 8, 0x001fffffu); /* resource-id mask */
	put32(body + 12, 256);        /* motion buffer size */
	put16(body + 16, 5);          /* vendor length: "fakex" */
	put16(body + 18, 65535);      /* maximum request length */
	body[20] = 1;                 /* number of screens */
	body[21] = 1;                 /* number of pixmap formats */
	body[22] = 0;                 /* image byte order: LSB first */
	body[23] = 0;                 /* bitmap bit order */
	body[24] = 32;                /* bitmap scanline unit */
	body[25] = 32;                /* bitmap scanline pad */
	body[26] = 8;                 /* min keycode */
	body[27] = 255;               /* max keycode */

	memcpy(body + 32, "fakex", 5); /* padded to 8 by the zero fill */

	body[40] = 24; /* one pixmap format: depth, bpp, scanline pad, 5 pad */
	body[41] = 32;
	body[42] = 32;

	/* The screen. xrootclock reads only the first field, the root window. */
	put32(body + 48, FAKE_ROOT_WINDOW);
	put32(body + 52, 0x20u); /* default colormap */
	put32(body + 56, 0x00ffffffu);
	put32(body + 60, 0);
	put32(body + 64, 0);
	put16(body + 68, 1920);
	put16(body + 70, 1080);
	put16(body + 72, 508);
	put16(body + 74, 285);
	put16(body + 76, 1);
	put16(body + 78, 1);
	put32(body + 80, 0x21u); /* root visual */
	body[84] = 0;            /* backing store */
	body[85] = 0;            /* save unders */
	body[86] = 24;           /* root depth */
	body[87] = 0;            /* number of depths */

	return write_all(file_descriptor, prefix, sizeof prefix) && write_all(file_descriptor, body, sizeof body);
}

static bool send_setup_refusal(int file_descriptor)
{
	static const char reason[] = "fakex refuses this connection";

	uint8_t prefix[8];
	uint8_t body[32];
	size_t  length = sizeof reason - 1;

	memset(prefix, 0, sizeof prefix);
	memset(body, 0, sizeof body);

	prefix[0] = 0; /* failed */
	prefix[1] = (uint8_t)length;
	put16(prefix + 2, 11);
	put16(prefix + 4, 0);
	put16(prefix + 6, (uint16_t)(sizeof body / 4));

	memcpy(body, reason, length);

	return write_all(file_descriptor, prefix, sizeof prefix) && write_all(file_descriptor, body, sizeof body);
}

static bool send_reply(int file_descriptor)
{
	uint8_t packet[32];

	memset(packet, 0, sizeof packet);

	packet[0] = 1; /* reply */
	packet[1] = 0;
	put16(packet + 2, sequence);
	put32(packet + 4, 0);
	put32(packet + 8, FAKE_ROOT_WINDOW);

	return write_all(file_descriptor, packet, sizeof packet);
}

static bool send_error(int file_descriptor, uint8_t code, uint8_t opcode)
{
	uint8_t packet[32];

	memset(packet, 0, sizeof packet);

	packet[0] = 0; /* error */
	packet[1] = code;
	put16(packet + 2, sequence);
	put32(packet + 4, 0);
	put16(packet + 8, 0);
	packet[10] = opcode;

	return write_all(file_descriptor, packet, sizeof packet);
}

/* Log the property text with non-printables escaped, so a shell test can
 * compare a single stable line. */
static void log_property(const uint8_t *request, size_t units)
{
	size_t i;

	printf("CHANGEPROPERTY mode=%u window=0x%08x property=%u type=%u format=%u units=%zu data=", request[1],
	       get32(request + 4), get32(request + 8), get32(request + 12), request[16], units);

	for (i = 0; i < units; i++)
	{
		uint8_t byte = request[24 + i];

		if (byte >= 0x20 && byte < 0x7f)
			putchar((int)byte);
		else
			printf("\\x%02x", byte);
	}

	putchar('\n');
}

static void serve(int file_descriptor)
{
	static uint8_t request[MAX_REQUEST];

	uint8_t prefix[12];
	size_t  skip;

	sequence = 0;

	if (!read_all(file_descriptor, prefix, sizeof prefix))
		return;

	skip = pad4(get16(prefix + 6)) + pad4(get16(prefix + 8));

	if (skip > sizeof request || (skip > 0 && !read_all(file_descriptor, request, skip)))
		return;

	printf("SETUP authname=%u authdata=%u\n", get16(prefix + 6), get16(prefix + 8));
	fflush(stdout);

	if (server_mode == MODE_REFUSE)
	{
		(void)send_setup_refusal(file_descriptor);

		printf("DISCONNECT\n");
		fflush(stdout);

		return;
	}

	if (!send_setup_success(file_descriptor))
		return;

	while (running)
	{
		uint8_t  header[4];
		uint16_t length;
		size_t   rest;

		if (!read_all(file_descriptor, header, sizeof header))
			break;

		sequence++;
		length = get16(header + 2);

		if (length == 0 || (size_t)length * 4u > sizeof request)
			break;

		rest = ((size_t)length * 4u) - sizeof header;

		memcpy(request, header, sizeof header);

		if (rest > 0 && !read_all(file_descriptor, request + sizeof header, rest))
			break;

		printf("REQUEST opcode=%u length=%u\n", request[0], length);

		if (request[0] == 18) /* ChangeProperty */
		{
			log_property(request, get32(request + 20));

			if (server_mode == MODE_ERROR && !send_error(file_descriptor, 9, 18))
				break;
		}
		else if (request[0] == 43) /* GetInputFocus */
		{
			printf("GETINPUTFOCUS\n");

			if (server_mode != MODE_MUTE && !send_reply(file_descriptor))
				break;
		}

		fflush(stdout);
	}

	printf("DISCONNECT\n");
	fflush(stdout);
}

int main(int argc, char *argv[])
{
	union
	{
		struct sockaddr    any;
		struct sockaddr_un local;
	} address;

	struct sigaction action;
	const char      *mode_name = (argc > 2) ? argv[2] : "ok";
	int              listener;
	int              probe;

	if (argc < 2)
	{
		fprintf(stderr, "usage: fakex DISPLAYNUM [ok|refuse|error|split|mute]\n");

		return 2;
	}

	if (strcmp(mode_name, "ok") == 0)
		server_mode = MODE_OK;
	else if (strcmp(mode_name, "refuse") == 0)
		server_mode = MODE_REFUSE;
	else if (strcmp(mode_name, "error") == 0)
		server_mode = MODE_ERROR;
	else if (strcmp(mode_name, "split") == 0)
		server_mode = MODE_SPLIT;
	else if (strcmp(mode_name, "mute") == 0)
		server_mode = MODE_MUTE;
	else
	{
		fprintf(stderr, "fakex: unknown mode '%s'\n", mode_name);

		return 2;
	}

	if (snprintf(socket_path, sizeof socket_path, "/tmp/.X11-unix/X%s", argv[1]) < 0)
		return 2;

	memset(&address, 0, sizeof address);
	address.local.sun_family = AF_UNIX;
	memcpy(address.local.sun_path, socket_path, strlen(socket_path) + 1);

	/* Take over a stale socket, but never steal a live one: a concurrent run
	 * (or the real X server) must make us fail so the caller picks another
	 * display number. */
	probe = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);

	if (probe >= 0)
	{
		bool in_use = connect(probe, &address.any, (socklen_t)sizeof address.local) == 0;

		close(probe);

		if (in_use)
		{
			fprintf(stderr, "fakex: '%s' is already served\n", socket_path);

			return 1;
		}

		unlink(socket_path);
	}

	listener = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);

	if (listener < 0)
	{
		perror("fakex: socket");

		return 1;
	}

	if (bind(listener, &address.any, (socklen_t)sizeof address.local) != 0)
	{
		fprintf(stderr, "fakex: cannot bind '%s': %s\n", socket_path, strerror(errno));
		close(listener);

		return 1;
	}

	if (listen(listener, 8) != 0)
	{
		perror("fakex: listen");
		close(listener);

		return 1;
	}

	memset(&action, 0, sizeof action);
	action.sa_handler = on_signal;
	sigemptyset(&action.sa_mask);
	sigaction(SIGINT, &action, NULL);
	sigaction(SIGTERM, &action, NULL);

	memset(&action, 0, sizeof action);
	action.sa_handler = SIG_IGN;
	sigemptyset(&action.sa_mask);
	sigaction(SIGPIPE, &action, NULL);

	printf("LISTENING %s\n", socket_path);
	fflush(stdout);

	while (running)
	{
		int client = accept(listener, NULL, NULL);

		if (client < 0)
		{
			if (errno == EINTR)
				continue;

			break;
		}

		serve(client);
		close(client);
	}

	close(listener);
	unlink(socket_path);

	return 0;
}
