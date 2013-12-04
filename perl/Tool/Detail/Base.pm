package Tool::Detail::Base;
use Moose;
use warnings FATAL => 'all';

use Factory::ManifestAllocation;
use File::Path qw();
use File::Temp qw();
use Log::Log4perl qw();
use Manifest::Writer;
use Memoize qw();
use Result::Input;
use Result::Output;
use Result;
use Tool::Detail::AttributeSetter;
use Tool::Detail::Contextual;
use Translator;

with 'WorkflowCompatibility::Role';


Log::Log4perl->easy_init($Log::Log4perl::DEBUG);

my $logger = Log::Log4perl->get_logger();


has test_name => (
    is => 'rw',
    traits => ['Param', 'Contextual'],
    required => 1,
);
has _process => (
    is => 'rw',
    traits => ['Param', 'Contextual'],
    required => 1,
);
has _step_label => (
    is => 'rw',
    traits => ['Param', 'Contextual'],
    required => 1,
);

has _raw_inputs => (
    is => 'rw',
    isa => 'HashRef',
);
has _original_working_directory => (
    is => 'rw',
    isa => 'Str',
);
has _workspace_path => (
    is => 'rw',
    isa => 'Str',
);


sub inputs {
    my $class = shift;

    return map {$_->name} grep {$_->does('Input')}
        $class->meta->get_all_attributes;
}
Memoize::memoize('inputs');

sub outputs {
    my $class = shift;

    return map {$_->name} grep {$_->does('Output')}
        $class->meta->get_all_attributes;
}
Memoize::memoize('outputs');

sub params {
    my $class = shift;

    return map {$_->name} grep {$_->does('Param')}
        $class->meta->get_all_attributes;
}
Memoize::memoize('params');


sub shortcut {
    my $self = shift;

    $logger->info("Attempting to shortcut ", ref $self,
        " with test name (", $self->test_name, ")");

    my $result = Result->lookup(inputs => $self->_inputs_as_hashref,
        tool_class_name => ref $self, test_name => $self->test_name);

    if ($result) {
        $logger->info("Found matching result with lookup hash (",
            $result->lookup_hash, ")");
        $self->_set_outputs_from_result($result);

        $self->_create_process_step($result);
        return 1;

    } else {
        $logger->info("No matching result found for shortcut");
        return;
    }
}

sub _inputs_as_hashref {
    my $self = shift;

    my %inputs;
    for my $input_name ($self->_non_contextual_input_names) {
        $inputs{$input_name} = $self->$input_name;
    }

    return \%inputs;
}

sub _non_contextual_input_names {
    my $self = shift;

    return $self->inputs, $self->_non_contextual_params;
}

sub _non_contextual_params {
    my $self = shift;
    return map {$_->name} grep {$_->does('Param') && !$_->does('Contextual')}
        $self->meta->get_all_attributes;
}
Memoize::memoize('_non_contextual_params');


sub _property_names {
    my $self = shift;

    return map {$_->property_name} $self->__meta__->properties(@_);
}

sub _set_outputs_from_result {
    my ($self, $result) = @_;

    for my $output ($result->outputs) {
        my $name = $output->name;
        $self->$name($output->value_id);
    }

    return;
}

sub _create_process_step {
    my ($self, $result) = @_;

    $self->_translate_inputs('_process', '_step_label');
    ProcessStep->create(process => $self->_process, result => $result,
        label => $self->_step_label);

    return;
}

sub _translate_inputs {
    my $self = shift;

    my $translator = Translator->new();
    for my $input_name (@_) {
        $self->$input_name($translator->resolve_scalar_or_url($self->$input_name));
    }

    return;
}


sub execute {
    my $self = shift;

    $self->_setup;
    $logger->info("Process id: ", $self->_process->id);

    eval {
        $self->execute_tool;
    };

    my $error = $@;
    if ($error) {
        unless ($ENV{GENOME_SAVE_WORKSPACE_ON_FAILURE}) {
            $self->_cleanup;
        }
        die $error;

    } else {
        $self->_save;
        $self->_cleanup;
    }

    return 1;
}

sub _setup {
    my $self = shift;

    $self->_setup_workspace;
    $self->_cache_raw_inputs;
    $self->_translate_inputs($self->_translatable_input_names);

    return;
}

sub _setup_workspace {
    my $self = shift;

    $self->_workspace_path(File::Temp::tempdir(CLEANUP => 1));
    $self->_original_working_directory(Cwd::cwd());
    chdir $self->_workspace_path;

    return;
}

sub _cache_raw_inputs {
    my $self = shift;

    $self->_raw_inputs($self->_inputs_as_hashref);

    return;
}

my @_TRANSLATABLE_TYPES = (
    'File',
    'Process',
);
sub _translatable_input_names {
    my $self = shift;

    return map {$self->_property_names(is_input => 1, data_type => $_)}
        @_TRANSLATABLE_TYPES;
}

sub execute_tool {
    die 'Abstract method';
}

sub _cleanup {
    my $self = shift;

    chdir $self->_original_working_directory;
    File::Path::rmtree($self->_workspace_path);

    return;
}

sub _save {
    my $self = shift;

    $self->_verify_outputs_in_workspace;

    my $allocation = $self->_save_outputs;
    $self->_translate_outputs($allocation);
    my $result = $self->_create_checkpoint($allocation);
    $self->_create_process_step($result);

    return;
};

sub _verify_outputs_in_workspace { }

sub _save_outputs {
    my $self = shift;

    $self->_create_output_manifest;
    my $allocation = Factory::ManifestAllocation::from_manifest(
        $self->_workspace_manifest_path);

    $logger->info("Saved outputs from tool '", $self->class,
        "' to allocation (", $allocation->id, ")");
    $allocation->reallocate;

    return $allocation;
}

sub _create_output_manifest {
    my $self = shift;

    my $writer = Manifest::Writer->create(
        manifest_file => $self->_workspace_manifest_path);
    for my $output_name ($self->_saved_file_names) {
        next if $output_name eq 'result';  # legacy baggage

        my $path = $self->$output_name || '';
        if (-e $path) {
            $writer->add_file(path => $path, kilobytes => -s $path,
                tag => $output_name);
        } else {
            confess sprintf("Failed to save output '%s'", $path);
        }
    }
    $writer->save;

    return;
}

sub _workspace_manifest_path {
    my $self = shift;
    return File::Spec->join($self->_workspace_path, 'manifest.xml');
}

sub _saved_file_names {
    my $self = shift;

    # XXX Broken
    return List::MoreUtils::uniq(
        $self->_property_names(is_output => 1, data_type => 'File'),
        $self->_property_names(is_saved => 1));
}

sub _translate_outputs {
    my ($self, $allocation) = @_;

    for my $output_file_name ($self->_translatable_output_names) {
        $self->$output_file_name(
            _translate_output($allocation->id, $output_file_name)
        );
    }

    return;
}

sub _translatable_output_names {
    my $self = shift;

    # XXX Broken
    return map {$self->_property_names(is_output => 1, data_type => $_)}
        @_TRANSLATABLE_TYPES;
}

sub _create_checkpoint {
    my ($self, $allocation) = @_;

    my $result = Result->create(tool_class_name => $self->class,
        test_name => $self->test_name, allocation => $allocation,
        owner => $self->_process);

    for my $input_name ($self->_non_contextual_input_names) {
        my $input = Result::Input->create(name => $input_name,
            value_class_name => 'UR::Value',
            value_id => $self->_raw_inputs->{$input_name},
            result_id => $result->id);
    }

    for my $output_name ($self->outputs) {
        Result::Output->create(name => $output_name,
            value_class_name => 'UR::Value',
            value_id => $self->$output_name,
            result_id => $result->id);
    }

    $result->update_lookup_hash;

    return $result;
}



no Tool::Detail::AttributeSetter;
__PACKAGE__->meta->make_immutable;
