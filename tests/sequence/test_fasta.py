# Copyright 2017 Patrick Kunzmann.
# This code is part of the Biopython distribution and governed by its
# license.  Please see the LICENSE file that should have been included
# as part of this package.

import biopython.sequence as seq
import biopython.sequence.io.fasta as fasta
import numpy as np
import os
import os.path
from .util import data_dir
import pytest

   
def test_access():
    path = os.path.join(data_dir, "nuc.fasta")
    file = fasta.FastaFile()
    file.read(path)
    assert file["dna sequence"] == "ACGCTACGT"
    assert file["another dna sequence"] == "A"
    assert file["third dna sequence"] == "ACGT"
    assert dict(file) == {"dna sequence" : "ACGCTACGT",
                          "another dna sequence" : "A",
                          "third dna sequence" : "ACGT"}
    file["another dna sequence"] = "AA"
    del file["dna sequence"]
    file["yet another sequence"] = "ACGT"
    assert dict(file) == {"another dna sequence" : "AA",
                          "third dna sequence" : "ACGT",
                          "yet another sequence" : "ACGT"}

def test_conversion():
    path = os.path.join(data_dir, "nuc.fasta")
    file = fasta.FastaFile()
    file.read(path)
    assert seq.NucleotideSequence("ACGCTACGT") == fasta.get_sequence(file)
    
    seq_dict = fasta.get_sequences(file)
    file2 = fasta.FastaFile()
    fasta.set_sequences(file2, seq_dict)
    seq_dict2 = fasta.get_sequences(file2)
    assert seq_dict == seq_dict2
    
    file3 = fasta.FastaFile()
    fasta.set_sequence(file3, seq.NucleotideSequence("AACCTTGG"))
    assert file3["sequence"] == "AACCTTGG"
    
    path = os.path.join(data_dir, "prot.fasta")
    file4 = fasta.FastaFile()
    file4.read(path)
    assert seq.ProteinSequence("YAHGFRTGS") == fasta.get_sequence(file4)
    
    path = os.path.join(data_dir, "invalid.fasta")
    file5 = fasta.FastaFile()
    file5.read(path)
    with pytest.raises(ValueError):
        seq.NucleotideSequence(fasta.get_sequence(file5))