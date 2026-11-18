/*-
 * Copyright (c) 2003-2010 Tim Kientzle
 * Copyright (c) 2016 Martin Matuska

 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR(S) ``AS IS'' AND ANY EXPRESS OR
 * IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
 * OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 * IN NO EVENT SHALL THE AUTHOR(S) BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */


// A small ABI surface from libarchive 3.7.4 for macOS, whose SDK ships the
// library linker stubs without archive.h and archive_entry.h.
#ifndef MUK_SYSTEM_ARCHIVE_H
#define MUK_SYSTEM_ARCHIVE_H

#include <stdint.h>
#include <sys/types.h>

struct archive;
struct archive_entry;
#define ARCHIVE_EOF 1
#define ARCHIVE_OK 0

struct archive *archive_read_new(void);
int archive_read_support_filter_bzip2(struct archive *);
int archive_read_support_filter_gzip(struct archive *);
int archive_read_support_filter_xz(struct archive *);
int archive_read_support_format_7zip(struct archive *);
int archive_read_support_format_rar(struct archive *);
int archive_read_support_format_rar5(struct archive *);
int archive_read_support_format_tar(struct archive *);
int archive_read_support_format_zip(struct archive *);
int archive_read_add_passphrase(struct archive *, const char *);
int archive_read_open_fd(struct archive *, int, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_data_skip(struct archive *);
int archive_read_free(struct archive *);
const char *archive_error_string(struct archive *);

struct archive *archive_write_new(void);
int archive_write_set_format_zip(struct archive *);
int archive_write_set_format_option(struct archive *, const char *, const char *, const char *);
int archive_write_set_passphrase(struct archive *, const char *);
int archive_write_open_fd(struct archive *, int);
int archive_write_header(struct archive *, struct archive_entry *);
ssize_t archive_write_data(struct archive *, const void *, size_t);
int archive_write_finish_entry(struct archive *);
int archive_write_close(struct archive *);
int archive_write_free(struct archive *);

struct archive_entry *archive_entry_new(void);
void archive_entry_free(struct archive_entry *);
const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);
void archive_entry_set_pathname_utf8(struct archive_entry *, const char *);
void archive_entry_set_filetype(struct archive_entry *, unsigned int);
void archive_entry_set_perm(struct archive_entry *, mode_t);
void archive_entry_set_size(struct archive_entry *, int64_t);

#endif
