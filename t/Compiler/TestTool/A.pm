package Compiler::TestTool::A;
use Tool;
use warnings FATAL => 'all';

has_input 'ai1';
has_output 'ao1';


__PACKAGE__->meta->make_immutable;
