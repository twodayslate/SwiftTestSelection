# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: AGPL-3.0-only
"""Read frontend input lists, which contain one literal filename per line.

These are not shell response files: spaces, quotes and backslashes belong to
filenames. Preserve input spelling/order for supplementary output-map keys.
"""
import hashlib
import pathlib


def frontend_inputs(arguments, directory):
    sources = []
    primaries = []
    lists = {}
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument in ['-filelist', '-primary-filelist', '-primary-file']:
            index += 1
            if index == len(arguments):
                raise ValueError('Missing operand for ' + argument)
            operand = arguments[index]
            if argument == '-primary-file':
                sources.append(operand)
                primaries.append(operand)
            else:
                path = pathlib.Path(directory) / operand
                data = path.read_bytes()
                lists[str(path)] = hashlib.sha256(data).hexdigest()
                names = [name for name in data.decode('utf-8').split('\n') if name]
                if argument == '-filelist': sources.extend(names)
                else: primaries.extend(names)
        elif argument.endswith('.swift'):
            sources.append(argument)
        index += 1
    # -primary-filelist marks members of the input inventory, in input order.
    primary_set = set(primaries)
    if not primary_set.issubset(sources):
        raise ValueError('Primary files are absent from the source inventory')
    sources = list(dict.fromkeys(sources))
    return sources, [name for name in sources if name in primary_set], lists
