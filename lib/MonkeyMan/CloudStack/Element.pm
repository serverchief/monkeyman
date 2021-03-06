package MonkeyMan::CloudStack::Element;

use strict;
use warnings;
use feature "switch";

use MonkeyMan::Constants;

use Data::Dumper;

use Moose::Role;
use namespace::autoclean;

with 'MonkeyMan::ErrorHandling';



has 'mm' => (
    is          => 'ro',
    isa         => 'MonkeyMan',
    predicate   => 'has_mm',
    writer      => '_set_mm',
    required    => 'yes'
);
has 'init_load_dom' => (
    is          => 'ro',
    isa         => 'HashRef',
    predicate   => 'has_init_load_dom',
    init_arg    => 'load_dom'
);
has 'dom' => (
    is          => 'ro',
    isa         => 'Object',
    predicate   => 'has_dom',
    reader      => 'dom',
    writer      => '_set_dom'
);



sub BUILD {

    my $self = shift;

    # Load information if it's neccessary
 
    if($self->has_init_load_dom) {
        my $result = $self->load_dom(%{$self->init_load_dom});
        given($result) {
            when(undef)                     { die($self->error_message) }
            when(scalar(@{ $result }) < 1)  { die("The element hasn't been found") }
            when(scalar(@{ $result }) > 1)  { die("Too many elements have been found") }
        }
    }
    
}



sub load_dom {
    
    my($self, %input) = @_;

    return($self->error("Required parameters haven't been defined"))
        unless(%input);
    return($self->error("MonkeyMan hasn't been initialized"))
        unless($self->has_mm);
    return($self->error("The logger hasn't been initialized"))
        unless($self->mm->has_logger);
    return($self->error("CloudStack's API connector hasn't been initialized"))
        unless($self->mm->has_cloudstack_api);

    my $mm  = $self->mm;
    my $log = $mm->logger;
    my $api = $mm->cloudstack_api;

    my $nodes = [];             # resulting nodes are to be stored here
    my $dom_unfiltered;         # the source DOM
    my $dom_filtered;           # the resulting DOM

    # Load the predetermined DOM (if given) or the full list of elements

    if(ref($input{'dom'}) eq 'XML::LibXML::Document') {

        $log->debug("Loading $self with the prederermined DOM: $input{'dom'}");

        push(@{ $nodes }, eval {   $input{'dom'}->documentElement });
        return($self->error("Can't $input{'dom'}->documentElement(): $@")) if($@);

    } else {

        $log->debug(
            "Have got a request for a " . ref($self) .
            ", it shall match following conditions: " .
            join(" && ",
                map { "'$_' eq '$input{'conditions'}->{$_}'" } (
                    keys(%{ $input{'conditions'} })
                )
            )
        );

        $dom_unfiltered = $api->run_command(
            # FIXME: it's quite dangerous to pass all parameters without any
            # security checks, so I should consider adding a couple of them here...
            parameters => $self->_load_full_list_command
        );
        return($self->error($api->error_message)) unless(defined($dom_unfiltered));

    }

    # Apply filters, checking for matching conditions

    foreach my $condition (keys(%{ $input{'conditions'} }), 'FINAL') {

        # Don't do anything if we already have some predetermined DOM

        last if(ref($input{'dom'}) eq 'XML::LibXML::Document');

        # Create a new DOM for storing resulting nodes

        $dom_filtered = eval {     XML::LibXML::Document->createDocument("1.0", "UTF-8"); };
        return($self->error("Can't XML::LibXML::Document->createDocument(): $@")) if($@);

        # Do we have the XPath-query for that condition?

        my $xpath_query = $self->_generate_xpath_query(
            find    => {
                attribute   => $condition,
                value       => $input{'conditions'}->{$condition}
            }
        );
        return($self->error($self->error_message))
            unless(defined($xpath_query));

        # Okay, let's apply the filter

        $nodes = $api->query_xpath($dom_unfiltered, $xpath_query);
        return($self->error($api->error_message))
            unless(defined($nodes));

        # So, how many nodes have we got? If there are no nodes, let's stop
        # working and return nothing.

        if(scalar(@{ $nodes }) < 1) {
            $log->trace(
                "Nothing matches the condition: " .
                "$condition == $input{'conditions'}->{$condition}"
            );
            last;
        }

        # If it's not the last pass, prepare the new "unfiltered" DOM filled
        # with resulting nodes of this pass

        if($condition ne 'FINAL') {

            # Building all required parents' nodes
        
            my @node_names = (split('/', eval { ${ $nodes }[0]->parentNode->nodePath; }));
            return($self->error("Can't ${ $nodes }[0]->parentNode()->nodePath(): $@")) if($@);

            my $node_to_add_children = $dom_filtered;

            foreach my $node_name (@node_names) {

                next unless ($node_name);

                my $node = eval {          $dom_filtered->createElement($node_name); };
                return($self->error("Can't $dom_filtered->createElement(): $@")) if($@);

                eval {                     $node_to_add_children->addChild($node); };
                return($self->error("Can't $node_to_add_children->addChild(): $@")) if($@);

                $node_to_add_children = $node;

            }

            # Okay, now let's attach resulting nodes to the main node

            my $child_last;

            foreach my $node (@{ $nodes }) {

                my $child_last = eval {    $node_to_add_children->addChild($node); };
                return($self->error("Can't $node_to_add_children->addChild() $@")) if ($@);

            }

            eval { $node_to_add_children->setAttribute("count", scalar(@{ $nodes })); };
            return(self->error("Can't $node_to_add_children->setAttribute(): $@")) if($@);

            $dom_unfiltered = $dom_filtered;

        }

    }

    # Okay, what have we got?

    my @results;
    my $results_got = 0;

    foreach my $node (@{ $nodes }) {

        my $dom = eval {           XML::LibXML::Document->createDocument("1.0", "UTF-8"); };
        return($self->error("Can't XML::LibXML::Document->createDocument(): $@")) if($@);

        eval {                     $dom->addChild($node); };
        return($self->error("Can't $dom->addChild(): $@")) if($@);

        push(@results, $dom);

        $log->trace(
            "The following information have been found: " .
            $dom->toString(1)
        );

        $results_got++;

    }

    given($results_got) {
        when($_ < 1) { $log->debug("The requested parameter haven't been got") }
        when($_ > 1) { $log->debug("$results_got results have been got") }
        default {
            $self->_set_dom($results[0]);
            $log->debug("$self element has been loaded with " . $self->dom);
            $log->trace(
                "Now we've got the following information about $self: " .
                $self->dom->toString(1)
            );
        }
    }

    return(\@results);

}



sub get_parameter {

    my($self, $parameter) = @_;

    return($self->error("The soaked parameter hasn't been defined"))
        unless(defined($parameter));
    return($self->error("MonkeyMan hasn't been initialized"))
        unless($self->has_mm);
    return($self->error("The logger hasn't been initialized"))
        unless($self->mm->has_logger);
    return($self->error("CloudStack's API connector hasn't been initialized"))
        unless($self->mm->has_cloudstack_api);

    my $mm  = $self->mm;
    my $log = $mm->logger;
    my $api = $mm->cloudstack_api;

    $log->trace("Getting the $parameter parameter of $self");

    my $xpath_query = $self->_generate_xpath_query(
        get => $parameter
    );
    return($self->error($self->error_message))
        unless(defined($xpath_query));

    my $results = $api->query_xpath($self->dom, $xpath_query);
    return($self->error($api->error_message))
        unless(defined($results));

    my $results_got = scalar(@{ $results });

    given($results_got) {
        when($_ < 1) { $log->trace("The requested parameter haven't been got") }
        when($_ > 1) { $log->warn("$results_got results have been got, but the caller is expecting only 1, returning the first one") }
    }

    my $result = eval { $results_got ? ${ $results }[0]->textContent : undef; };
    return($self->error("Can't ${ $results }[0]->textContent(): $@")) if($@);

    return($result);

}



sub find_related_to_me {

    my($self, $what_to_find) = @_;

    return($self->error("The type of soaked elements hasn't been defined"))
        unless(defined($what_to_find));
    return($self->error("The element's information haven't been loaded"))
        unless($self->has_dom);
    return($self->error($self->has_error) ? $self->error_message : "The ID of the element is unknown")
        unless($self->get_parameter('id'));
    return($self->error("MonkeyMan hasn't been initialized"))
        unless($self->has_mm);
    return($self->error("The logger hasn't been initialized"))
        unless($self->mm->has_logger);
    return($self->error("CloudStack's API connector hasn't been initialized"))
        unless($self->mm->has_cloudstack_api);

    my $mm  = $self->mm;
    my $log = $mm->logger;
    my $api = $mm->cloudstack_api;

    $log->trace("Going to look for ${what_to_find}s related to $self");

    my $module_name = eval {
        given($what_to_find) {
            when('domain')          { return('Domain'); }
            when('virtualmachine')  { return('VirtualMachine'); }
            when('volume')          { return('Volume'); }
            default {
                die("I'm not able to look for related ${what_to_find}s yet");
            }
        };
    };
    return($self->error($@)) if($@);

    my $quasi_object = eval {
        require "MonkeyMan/CloudStack/Elements/$module_name.pm";
         return("MonkeyMan::CloudStack::Elements::$module_name"->new(mm => $mm));
    };
    return($self->error("Can't MonkeyMan::CloudStack::Elements::${module_name}->new(): $@")) if($@);

    my $objects = $quasi_object->find_related_to_given($self);
    return($self->error($quasi_object->error_message)) unless(defined($objects));
    return($objects);

}



sub find_related_to_given {

    my($self, $key_element) = @_;

    return($self->error("The key element hasn't been defined"))
        unless(defined($key_element));
    return($self->error("The key element's information haven't been loaded"))
        unless($key_element->has_dom);
    return($self->error($self->has_error) ? $self->error_message : "The ID of the element is unknown")
        unless($key_element->get_parameter('id'));
    return($self->error("MonkeyMan hasn't been initialized"))
        unless($self->has_mm);
    return($self->error("The logger hasn't been initialized"))
        unless($self->mm->has_logger);
    return($self->error("CloudStack's API connector hasn't been initialized"))
        unless($self->mm->has_cloudstack_api);

    my $mm  = $self->mm;
    my $log = $mm->logger;
    my $api = $mm->cloudstack_api;

    $log->trace("Looking for " . $self->element_type . "s related to $key_element");

    my $objects = $self->load_dom(
        conditions => {
            $key_element->element_type . "id" => $key_element->get_parameter('id')
        }
    );
    return($self->error($self->error_message)) unless(defined($objects));
    return($objects);

}



1;

