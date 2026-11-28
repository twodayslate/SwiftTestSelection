// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// SPDX-FileCopyrightText: 2026 Zachary Gorak
#include <stdbool.h>
#include <stdint.h>

/// Resolve reference occurrences from the primary file's actual compilation unit.
typedef void (*STSIndexReference)(void *context, unsigned line, unsigned column,
                                  const char *usr, unsigned long length, uint64_t roles);
bool sts_read_index(const char *library, const char *store, const char *unitOutput,
                    const char *module, const char *source, void *context, STSIndexReference visit);
