/*
 * base64 -- the BSD command line encoder macOS ships at /usr/bin/base64.
 *
 * WHY THIS EXISTS. The container had no base64 at all, and the first thing that noticed was
 * iTerm2 imgcat, which refused to run with
 *
 *     ERROR: missing dependency: can't find base64
 *
 * Apple does not build one in basic_cmds, where uuencode keeps its own base64.c for the -m flag and
 * exposes no separate tool, so there is nothing upstream to switch on. This is a first party
 * implementation of the interface macOS presents, and nothing more.
 *
 * THE INTERFACE MATTERS MORE THAN THE ALGORITHM, because scripts probe it. imgcat runs
 * base64 --version and reads the output: if it mentions GNU it passes -w0 to disable wrapping and
 * -di to decode, and otherwise it uses the BSD spelling, bare for encode and -D for decode. macOS
 * answers an unknown option with a usage message on stderr and a non zero status, which is exactly
 * what leads a script to the BSD branch, so that behaviour is deliberate here rather than an
 * oversight.
 *
 * And output is NOT wrapped unless -b asks for it. imgcat feeds the encoding straight into an OSC
 * escape sequence, where a stray newline would truncate the image.
 */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char kAlphabet[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static void usage(void)
{
    fprintf(stderr, "usage: base64 [-hDd] [-b num] [-i in_file] [-o out_file]\n");
    fprintf(stderr, "  -h, --help     display this message\n");
    fprintf(stderr, "  -D, -d         decode incoming base64 stream\n");
    fprintf(stderr, "  -b num         break encoded string into num character lines\n");
    fprintf(stderr, "  -i in_file     input file (default: stdin)\n");
    fprintf(stderr, "  -o out_file    output file (default: stdout)\n");
}

/* Wrapping is by COUNT OF EMITTED CHARACTERS, not by group, so a break can fall inside a quantum
 * exactly as the BSD tool does it. */
static void emit(FILE *out, int ch, long wrap, long *column)
{
    fputc(ch, out);
    if (wrap > 0) {
        (*column)++;
        if (*column == wrap) {
            fputc('\n', out);
            *column = 0;
        }
    }
}

static int encode(FILE *in, FILE *out, long wrap)
{
    unsigned char group[3];
    size_t got;
    long column = 0;

    while ((got = fread(group, 1, sizeof(group), in)) > 0) {
        unsigned long value = (unsigned long) group[0] << 16;

        if (got > 1) {
            value |= (unsigned long) group[1] << 8;
        }
        if (got > 2) {
            value |= (unsigned long) group[2];
        }

        emit(out, kAlphabet[(value >> 18) & 0x3f], wrap, &column);
        emit(out, kAlphabet[(value >> 12) & 0x3f], wrap, &column);
        emit(out, (got > 1) ? kAlphabet[(value >> 6) & 0x3f] : '=', wrap, &column);
        emit(out, (got > 2) ? kAlphabet[value & 0x3f] : '=', wrap, &column);
    }

    if (ferror(in)) {
        return -1;
    }
    /* A trailing newline only when the output was being wrapped and does not already end in one,
     * which is what the BSD tool leaves behind. */
    if (wrap > 0 && column != 0) {
        fputc('\n', out);
    }
    return 0;
}

static int decode(FILE *in, FILE *out)
{
    signed char reverse[256];
    unsigned long value = 0;
    int have = 0;
    int ch;
    size_t i;

    memset(reverse, -1, sizeof(reverse));
    for (i = 0; i < sizeof(kAlphabet) - 1; i++) {
        reverse[(unsigned char) kAlphabet[i]] = (signed char) i;
    }

    while ((ch = fgetc(in)) != EOF) {
        signed char bits;

        if (ch == '=') {
            break;
        }
        bits = reverse[(unsigned char) ch];
        if (bits < 0) {
            /* Whitespace and line breaks are skipped; anything else is malformed input, and the
             * BSD tool says so rather than quietly producing rubbish. */
            if (ch == '\n' || ch == '\r' || ch == ' ' || ch == '\t') {
                continue;
            }
            fprintf(stderr, "base64: invalid input\n");
            return -1;
        }

        value = (value << 6) | (unsigned long) bits;
        have += 6;
        if (have >= 8) {
            have -= 8;
            fputc((int) ((value >> have) & 0xff), out);
        }
    }

    return ferror(in) ? -1 : 0;
}

int main(int argc, char *argv[])
{
    int decoding = 0;
    long wrap = 0;
    const char *inPath = NULL;
    const char *outPath = NULL;
    FILE *in = stdin;
    FILE *out = stdout;
    int result;
    int opt;

    /* An unknown option, which includes the long --version a script may probe with, prints the
     * usage and fails. See the note at the top: that answer is what identifies this as the BSD
     * tool rather than the GNU one. */
    while ((opt = getopt(argc, argv, "hDdb:i:o:")) != -1) {
        switch (opt) {
        case 'D':
        case 'd':
            decoding = 1;
            break;
        case 'b':
            wrap = strtol(optarg, NULL, 10);
            if (wrap < 0) {
                wrap = 0;
            }
            break;
        case 'i':
            inPath = optarg;
            break;
        case 'o':
            outPath = optarg;
            break;
        case 'h':
            usage();
            return 0;
        default:
            usage();
            return 1;
        }
    }

    if (inPath != NULL && (in = fopen(inPath, "r")) == NULL) {
        fprintf(stderr, "base64: %s: %s\n", inPath, strerror(errno));
        return 1;
    }
    if (outPath != NULL && (out = fopen(outPath, "w")) == NULL) {
        fprintf(stderr, "base64: %s: %s\n", outPath, strerror(errno));
        return 1;
    }

    result = decoding ? decode(in, out) : encode(in, out, wrap);

    if (out != stdout) {
        fclose(out);
    }
    if (in != stdin) {
        fclose(in);
    }
    return (result == 0) ? 0 : 1;
}
