/*
Copyright (c) 2014 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.

Author: Leonardo de Moura
*/
#include "library/trace.h"
#include "library/constants.h"
#include "library/class.h"
#include "library/num.h"
#include "library/annotation.h"
#include "library/protected.h"
#include "library/io_state.h"
#include "library/print.h"
#include "library/util.h"
#include "library/pp_options.h"
#include "library/profiling.h"
#include "library/time_task.h"
#include "library/formatter.h"

namespace lean {
void initialize_library_core_module() {
    initialize_formatter();
    initialize_constants();
    initialize_profiling();
    initialize_trace();
}

void finalize_library_core_module() {
    finalize_trace();
    finalize_profiling();
    finalize_constants();
    finalize_formatter();
}

void initialize_library_module() {
    initialize_print();
    initialize_io_state();
    initialize_num();
    initialize_annotation();
    initialize_class();
    initialize_library_util();
    initialize_pp_options();
    initialize_time_task();
}

void finalize_library_module() {
    finalize_time_task();
    finalize_pp_options();
    finalize_library_util();
    finalize_class();
    finalize_annotation();
    finalize_num();
    finalize_io_state();
    finalize_print();
}
}
