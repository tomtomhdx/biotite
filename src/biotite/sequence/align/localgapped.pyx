# This source code is part of the Biotite package and is distributed
# under the 3-Clause BSD License. Please see 'LICENSE.rst' for further
# information.

__name__ = "biotite.sequence.align"
__author__ = "Patrick Kunzmann"
__all__ = ["align_local_gapped"]

cimport cython
cimport numpy as np
from .tracetable cimport follow_trace, get_trace_linear, get_trace_affine

import itertools
import numpy as np
from .alignment import Alignment


ctypedef np.int32_t int32
ctypedef np.int64_t int64
ctypedef np.uint8_t uint8
ctypedef np.uint16_t uint16
ctypedef np.uint32_t uint32
ctypedef np.uint64_t uint64

ctypedef fused CodeType1:
    uint8
    #uint16
    #uint32
    #uint64
ctypedef fused CodeType2:
    uint8
    #uint16
    #uint32
    #uint64


DEF INIT_SIZE = 100


def align_local_gapped(seq1, seq2, matrix, seed, int32 threshold,
                       gap_penalty=-10, max_number=1,
                       direction="both", score_only=False):
    """
    align_local_gapped(seq1, seq2, matrix, seed, threshold,
                       gap_penalty=-10, max_number=1,
                       direction="both", score_only=False)
    """
    # Check matrix alphabets
    if     not matrix.get_alphabet1().extends(seq1.get_alphabet()) \
        or not matrix.get_alphabet2().extends(seq2.get_alphabet()):
            raise ValueError("The sequences' alphabets do not fit the matrix")
    score_matrix = matrix.score_matrix()
    
    # Check if gap penalty is linear or affine
    if type(gap_penalty) == int:
        if gap_penalty >= 0:
            raise ValueError("Gap penalty must be negative")
    elif type(gap_penalty) == tuple:
        if gap_penalty[0] >= 0 or gap_penalty[1] >= 0:
                raise ValueError("Gap penalty must be negative")
    else:
        raise TypeError("Gap penalty must be either integer or tuple")
    
    # Check if max_number is reasonable
    if max_number < 1:
        raise ValueError(
            "Maximum number of returned alignments must be at least 1"
        )
    

    code1 = seq1.code
    code2 = seq2.code

    cdef int seq1_start, seq2_start
    seq1_start, seq2_start = seed
    if seq1_start < 0 or seq2_start < 0:
        raise IndexError("Seed must contain positive indices")
    if seq1_start >= len(code1) or seq2_start >= len(code2):
        raise IndexError(
            f"Seed {(seq1_start, seq2_start)} is out of bounds "
            f"for the sequences of length {len(code1)} and {len(code2)}"
        )
    

    cdef bint upstream
    cdef bint downstream
    if direction == "both":
        upstream = True
        downstream = True
    elif direction == "upstream":
        upstream = True
        downstream = False
    elif direction == "downstream":
        upstream = False
        downstream = True
    else:
        raise ValueError(f"Direction '{direction}' is invalid")
    # Range check to avoid negative indices
    if seq1_start == 0 or seq2_start == 0:
        upstream = False
    
    if threshold < 0:
        raise ValueError("The threshold value must be a non-negative integer")


    cdef int32 score
    cdef int32 total_score = 0
    # Separate alignment into two parts:
    # the regions upstream and downstream from the seed position
    if upstream:
        # For the upstream region the respective part of the sequence
        # must be reversed
        score, upstream_traces = _align_region(
            code1[seq1_start-1::-1], code2[seq2_start-1::-1],
            score_matrix, threshold, gap_penalty,
            max_number, score_only
        )
        total_score += score
        if upstream_traces is not None:
            # Undo the sequence reversing
            upstream_traces = [trace[::-1] for trace in upstream_traces]
            offset = np.array(seed) - 1
            for trace in upstream_traces:
                # Gap values (-1) are not transformed,
                # as gaps are not indices
                non_gap_mask = (trace != -1)
                # Second part of sequence reversing
                trace[non_gap_mask] *= -1
                # Add seed offset to trace indices
                trace[non_gap_mask[:, 0], 0] += offset[0]
                trace[non_gap_mask[:, 1], 1] += offset[1]
    
    if downstream:
        score, downstream_traces = _align_region(
            code1[seq1_start+1:], code2[seq2_start+1:],
            score_matrix, threshold, gap_penalty,
            max_number, score_only
        )
        total_score += score
        if downstream_traces is not None:
            offset = np.array(seed) + 1
            for trace in downstream_traces:
                trace[trace[:, 0] != -1, 0] += offset[0]
                trace[trace[:, 1] != -1, 1] += offset[1]
    
    total_score += score_matrix[code1[seq1_start], code2[seq2_start]]
    

    if score_only:
        return total_score
    else:
        if upstream and downstream:
            # Create cartesian product of upstream and downstream traces
            # Only consider max_number alignments
            traces = [
                np.concatenate([upstream_trace, [seed], downstream_trace])
                for _, (upstream_trace, downstream_trace) in zip(
                    range(max_number),
                    itertools.product(upstream_traces, downstream_traces)
                )
            ]
        elif upstream:
            traces = [
                np.concatenate([trace, [seed]]) for trace in upstream_traces
            ]
        elif downstream:
            traces = [
                np.concatenate([[seed], trace]) for trace in downstream_traces
            ]
        else:
            # 'direction == "upstream"', but the start index is 0 so no
            # upstream alignment is performed
            # -> the trace includes only the seed
            traces = [np.array(seed)[np.newaxis, :]]
        
        return [Alignment([seq1, seq2], trace, total_score)
                for trace in traces]


def _align_region(code1, code2, matrix, threshold, gap_penalty,
                  max_number, score_only):
    if type(gap_penalty) == int:
        affine_penalty = False
    else:
        affine_penalty = True
    
    
    
    init_size = (
        _min(len(code1)+1, INIT_SIZE),
        _min(len(code2)+1, INIT_SIZE)
    )
    trace_table = np.zeros(init_size, dtype=np.uint8)
    

    # Table filling
    ###############
    # Set the initial (upper left) score value to 'threshold + 1',
    # to be able to use '0' as minus infinity value
    init_score = threshold + 1
    if affine_penalty:
        m_table = np.zeros(init_size, dtype=np.int32)
        g1_table = np.zeros(init_size, dtype=np.int32)
        g2_table = np.zeros(init_size, dtype=np.int32)
        # This implementation does not initialize the entire first
        # row/column to avoid issues with premature pruning in the table
        # filling process
        m_table[0,0]  = init_score
        g1_table[0,0] = init_score
        g2_table[0,0] = init_score
        trace_table, m_table, g1_table, g2_table = _fill_align_table_affine(
            code1, code2, matrix, trace_table, m_table, g1_table, g2_table,
            threshold, gap_penalty[0], gap_penalty[1], score_only
        )
    else:
        score_table = np.zeros(init_size, dtype=np.int32)
        score_table[0,0] = init_score
        trace_table, score_table = _fill_align_table(
            code1, code2, matrix, trace_table, score_table, threshold,
            gap_penalty, score_only
        )
    
    # If only the score is desired, the traceback is not necessary
    if score_only:
        if affine_penalty:
            # The maximum score in the gap score tables do not need to
            # be considered, as these starting positions would indicate
            # that the alignment starts with a gap
            # Hence the maximum score value in these tables is always
            # less than in the match table
            max_score = np.max(m_table)
        else:
            max_score = np.max(score_table)
        # The initial score needs to be subtracted again,
        # since it was artificially added for convenience resaons
        return max_score - init_score, None
    
    
    # Traceback
    ###########
    # Stores all possible traces (= possible alignments)
    # A trace stores the indices of the aligned symbols
    # in both sequences
    trace_list = []
    # Lists of trace starting indices
    i_list = np.zeros(0, dtype=int)
    j_list = np.zeros(0, dtype=int)
    # List of start states
    # State specifies the table the trace starts in
    state_list = np.zeros(0, dtype=int)
    # The start point is the maximal score in the table
    # Multiple starting points possible,
    # when duplicates of maximal score exist 
    if affine_penalty:
        # Only consicder match table (see reason above)
        max_score = np.max(m_table)
        i_list, j_list = np.where((m_table == max_score))
        state_list = np.append(state_list, np.full(len(i_list), 1))
    else:
        max_score = np.max(score_table)
        i_list, j_list = np.where((score_table == max_score))
        # State is always 0 for linear gap penalty
        # since there is only one table
        state_list = np.zeros(len(i_list), dtype=int)

    # Follow the traces specified in state and indices lists
    cdef int curr_trace_count
    for k in range(len(i_list)):
        i_start = i_list[k]
        j_start = j_list[k]
        state_start = state_list[k]
        # Pessimistic array allocation:
        # The maximum trace length arises from an alignment, where each
        # symbol is aligned to a gap
        trace = np.full(( i_start+1 + j_start+1, 2 ), -1, dtype=np.int64)
        curr_trace_count = 1
        follow_trace(
            trace_table, False, i_start, j_start, 0, trace, trace_list,
            state=state_start, curr_trace_count=&curr_trace_count,
            max_trace_count=max_number,
            # Diagonals are only needed for banded alignments
            lower_diag=0, upper_diag=0
        )
    
    # Replace gap entries in trace with -1
    for i, trace in enumerate(trace_list):
        trace = np.flip(trace, axis=0)
        gap_filter = np.zeros(trace.shape, dtype=bool)
        gap_filter[np.unique(trace[:,0], return_index=True)[1], 0] = True
        gap_filter[np.unique(trace[:,1], return_index=True)[1], 1] = True
        trace[~gap_filter] = -1
        trace_list[i] = trace
    
    # Limit the number of generated alignments to `max_number`:
    # In most cases this is achieved by discarding branches in
    # 'follow_trace()', however, if multiple local alignment starts
    # are used, the number of created traces are the number of
    # starts times `max_number`
    trace_list = trace_list[:max_number]

    return max_score - init_score, trace_list


@cython.boundscheck(False)
@cython.wraparound(False)
def _fill_align_table(CodeType1[:] code1 not None,
                      CodeType2[:] code2 not None,
                      const int32[:,:] matrix not None,
                      uint8[:,:] trace_table not None,
                      int32[:,:] score_table not None,
                      int32 threshold,
                      int32 gap_penalty,
                      bint score_only):
    """
    """
    cdef int i, j, k=0
    # The ranges for i in the current (k=0) 
    # and previous (k=1, k=2) antidiagonals, that point to valid cells
    cdef int i_min_k_0=0, i_max_k_0=0
    cdef int i_min_k_1=0, i_max_k_1=0
    cdef int i_min_k_2=0, i_max_k_2=0
    # The pruned range for i and j in the current antidiagonal,
    # calculated from the previous antidiagonals
    cdef int i_min, i_max
    cdef int j_max
    # The maximum values for i and j ever encountered while iterating
    # over the antidiagonals -> used for final trimming of tables
    cdef int i_max_total=0, j_max_total=0

    cdef int32 from_diag, from_left, from_top
    cdef uint8 trace = 0
    cdef int32 score = 0
    cdef int32 max_score = score_table[0, 0]
    cdef int32 req_score = max_score - threshold

    # Instead of iteration over row and column,
    # iterate over antidiagonals and diagonals to achieve symmetric
    # treatment of both sequences
    for k in range(1, code1.shape[0] + code2.shape[0] + 1):
        # Prepare values for iteration
        i_min_k_2 = i_min_k_1
        i_max_k_2 = i_max_k_1
        i_min_k_1 = i_min_k_0
        i_max_k_1 = i_max_k_0
        # Reset values for iteration to most 'restrictive' values
        # These restrictive values are overwritten in the next iteration
        # if valid cells are present
        i_min_k_0 = k
        i_max_k_0 = 0

        # Prune index range for antidiagonal
        # to range where valid cells exist
        i_min = _min(i_min_k_1,     i_min_k_2 + 1)
        i_max = _max(i_max_k_1 + 1, i_max_k_2 + 1)
        # The index must also not be out of sequence range
        i_min = _max(i_min, k - code2.shape[0])
        i_max = _min(i_max, code1.shape[0])
        # The algorithm has finished,
        # if the calculated antidiagonal has no range of valid cells
        if i_min > i_max:
            break
        
        j_max = k - i_min
        # Expand ndarrays
        # if their size would be exceeded in the following iteration
        if i_max >= score_table.shape[0]:
            score_table = _extend_table(np.asarray(score_table), 0)
            if not score_only:
                trace_table = _extend_table(np.asarray(trace_table), 0)
        if j_max >= score_table.shape[1]:
            score_table = _extend_table(np.asarray(score_table), 1)
            if not score_only:
                trace_table = _extend_table(np.asarray(trace_table), 1)
        i_max_total = _max(i_max_total, i_max)
        j_max_total = _max(j_max_total, j_max)

        for i in range(i_min, i_max+1):
            j = k - i
            
            # Evaluate score from diagonal direction
            if i != 0 and j != 0:
                from_diag = score_table[i-1, j-1]
                # Check if score stems from cells that are valid
                if from_diag != 0:
                    # -1 in sequence index is necessary
                    # due to the shift of the sequences
                    # to the bottom/right in the table
                    from_diag += matrix[code1[i-1], code2[j-1]]
                else:
                    from_diag = 0
            else:
                from_diag = 0
            # Evaluate score through gap insertion
            if i != 0:
                from_top = score_table[i-1, j] + gap_penalty
            else:
                from_top = 0
            if j != 0:
                from_left = score_table[i, j-1] + gap_penalty
            else:
                from_left = 0
            
            if score_only:
                score = _max(from_diag, _max(from_left, from_top))
            else:
                trace = get_trace_linear(
                    from_diag, from_left, from_top, &score
                )
            
            # Check if the obtained score reaches the required threshold
            # and if they even exceed the maximum score
            if score >= req_score:
                if i_min_k_0 == k:
                    # 'i_min_k_0 == k'
                    # -> i_min_k_0 has not been set in this iteration, yet
                    i_min_k_0 = i
                i_max_k_0 = i
                score_table[i,j] = score
                if not score_only:
                    trace_table[i,j] = trace
                if score > max_score:
                    max_score = score
                    req_score = max_score - threshold
                
    
    return np.asarray(trace_table)[:i_max_total+1, :j_max_total+1], \
           np.asarray(score_table)[:i_max_total+1, :j_max_total+1]


@cython.boundscheck(False)
@cython.wraparound(False)
def _fill_align_table_affine(CodeType1[:] code1 not None,
                             CodeType2[:] code2 not None,
                             const int32[:,:] matrix not None,
                             uint8[:,:] trace_table not None,
                             int32[:,:] m_table not None,
                             int32[:,:] g1_table not None,
                             int32[:,:] g2_table not None,
                             int32 threshold,
                             int32 gap_open,
                             int32 gap_ext,
                             bint score_only):
    """
    """
    cdef int i, j, k=0
    # The ranges for i in the current (k=0) 
    # and previous (k=1, k=2) antidiagonals, that point to valid cells
    cdef int i_min_k_0=0, i_max_k_0=0
    cdef int i_min_k_1=0, i_max_k_1=0
    cdef int i_min_k_2=0, i_max_k_2=0
    # The pruned range for i and j in the current antidiagonal,
    # calculated from the previous antidiagonals
    cdef int i_min, i_max
    cdef int j_max
    # The maximum values for i and j ever encountered while iterating
    # over the antidiagonals -> used for final trimming of tables
    cdef int i_max_total=0, j_max_total=0

    cdef uint8 trace = 0
    cdef bint is_valid_cell

    cdef int32 mm_score, g1m_score, g2m_score
    cdef int32 mg1_score, g1g1_score
    cdef int32 mg2_score, g2g2_score
    cdef int32 m_score, g1_score, g2_score
    cdef int32 similarity_score
    cdef int32 max_score = m_table[0, 0]
    cdef int32 req_score = max_score - threshold

    # Instead of iteration over row and column,
    # iterate over antidiagonals and diagonals to achieve symmetric
    # treatment of both sequences
    for k in range(1, code1.shape[0] + code2.shape[0] + 1):
        # Prepare values for iteration
        i_min_k_2 = i_min_k_1
        i_max_k_2 = i_max_k_1
        i_min_k_1 = i_min_k_0
        i_max_k_1 = i_max_k_0
        # Reset values for iteration to most 'restrictive' values
        # These restrictive values are overwritten in the next iteration
        # if valid cells are present
        i_min_k_0 = k
        i_max_k_0 = 0

        # Prune index range for antidiagonal
        # to range where valid cells exist
        i_min = _min(i_min_k_1,     i_min_k_2 + 1)
        i_max = _max(i_max_k_1 + 1, i_max_k_2 + 1)
        # The index must also not be out of sequence range
        i_min = _max(i_min, k - code2.shape[0])
        i_max = _min(i_max, code1.shape[0])
        # The algorithm has finished,
        # if the calculated antidiagonal has no range of valid cells
        if i_min > i_max:
            break
        
        j_max = k - i_min
        # Expand ndarrays
        # if their size would be exceeded in the following iteration
        if i_max >= m_table.shape[0]:
            m_table  = _extend_table(np.asarray(m_table),  0)
            g1_table = _extend_table(np.asarray(g1_table), 0)
            g2_table = _extend_table(np.asarray(g2_table), 0)
            if not score_only:
                trace_table = _extend_table(np.asarray(trace_table), 0)
        if j_max >= m_table.shape[1]:
            m_table  = _extend_table(np.asarray(m_table),  1)
            g1_table = _extend_table(np.asarray(g1_table), 1)
            g2_table = _extend_table(np.asarray(g2_table), 1)
            if not score_only:
                trace_table = _extend_table(np.asarray(trace_table), 1)
        i_max_total = _max(i_max_total, i_max)
        j_max_total = _max(j_max_total, j_max)

        for i in range(i_min, i_max+1):
            j = k - i

            # Evaluate score from diagonal direction
            if i != 0 and j != 0:
                # -1 in sequence index is necessary
                # due to the shift of the sequences
                # to the bottom/right in the table
                similarity_score = matrix[code1[i-1], code2[j-1]]
                mm_score  = m_table[i-1,j-1]
                g1m_score = g1_table[i-1,j-1]
                g2m_score = g2_table[i-1,j-1]
                # Check if scores stem from cells that are valid
                if mm_score != 0:
                    mm_score += similarity_score
                if g1m_score != 0:
                    g1m_score += similarity_score
                if g2m_score != 0:
                    g2m_score += similarity_score
            else:
                mm_score = 0
                g1m_score = 0
                g2m_score = 0
            # Evaluate score through gap insertion
            # No transition from g1_table to g2_table and vice versa,
            # since this would mean adjacent gaps in both sequences;
            # a substitution makes more sense in this case
            if j != 0:
                mg1_score  =  m_table[i,j-1] + gap_open
                g1g1_score = g1_table[i,j-1] + gap_ext
            else:
                mg1_score  = 0
                g1g1_score = 0
            if i != 0:
                mg2_score  = m_table[i-1,j]  + gap_open
                g2g2_score = g2_table[i-1,j] + gap_ext
            else:
                mg2_score  = 0
                g2g2_score = 0
            
            
            
            if score_only:
                m_score = _max(mm_score, _max(g1m_score, g2m_score))
                g1_score = _max(mg1_score, mg1_score)
                g2_score = _max(mg2_score, g2g2_score)
            else:
                trace = get_trace_affine(
                    mm_score, g1m_score, g2m_score,
                    mg1_score, g1g1_score,
                    mg2_score, g2g2_score,
                    # The max score values to be written
                    &m_score, &g1_score, &g2_score
                )
            

            # Check if the obtained scores reach the required threshold
            # and if they even exceed the maximum score
            is_valid_cell = False

            if m_score >= req_score:
                if i_min_k_0 == k:
                    i_min_k_0 = i
                i_max_k_0 = i
                m_table[i,j] = m_score
                is_valid_cell = True
                if m_score > max_score:
                    max_score = m_score
                    req_score = max_score - threshold
            
            if g1_score >= req_score:
                if i_min_k_0 == k:
                    i_min_k_0 = i
                i_max_k_0 = i
                g1_table[i,j] = g1_score
                is_valid_cell = True
                if g1_score > max_score:
                    max_score = g1_score
                    req_score = max_score - threshold
            
            if g2_score >= req_score:
                if i_min_k_0 == k:
                    i_min_k_0 = i
                i_max_k_0 = i
                g2_table[i,j] = g2_score
                is_valid_cell = True
                if g2_score > max_score:
                    max_score = g2_score
                    req_score = max_score - threshold
            
            if is_valid_cell and not score_only:
                trace_table[i,j] = trace

    
    return np.asarray(trace_table)[:i_max_total+1, :j_max_total+1], \
           np.asarray(m_table    )[:i_max_total+1, :j_max_total+1], \
           np.asarray(g1_table   )[:i_max_total+1, :j_max_total+1], \
           np.asarray(g2_table   )[:i_max_total+1, :j_max_total+1]


def _extend_table(table, int dimension):
    if dimension == 0:
        new_shape = (table.shape[0] * 2, table.shape[1])
    else:
        new_shape = (table.shape[0], table.shape[1] * 2)
    new_table = np.zeros(new_shape, dtype=table.dtype)
    # Fill in exiisting data
    new_table[:table.shape[0], :table.shape[1]] = table
    return new_table


cdef inline int _min(int32 a, int32 b):
    return a if a < b else b

cdef inline int _max(int32 a, int32 b):
    return a if a > b else b