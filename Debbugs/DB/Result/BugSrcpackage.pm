use utf8;
package Debbugs::DB::Result::BugSrcpackage;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Debbugs::DB::Result::BugSrcpackage - Bug <-> source package mapping

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 COMPONENTS LOADED

=over 4

=item * L<DBIx::Class::InflateColumn::DateTime>

=back

=cut

__PACKAGE__->load_components("InflateColumn::DateTime");

=head1 TABLE: C<bug_srcpackage>

=cut

__PACKAGE__->table("bug_srcpackage");

=head1 ACCESSORS

=head2 bug_id

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

Bug id (matches bug)

=head2 src_pkg_id

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

Source package id (matches src_pkg)

=cut

__PACKAGE__->add_columns(
  "bug_id",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "src_pkg_id",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
);

=head1 UNIQUE CONSTRAINTS

=head2 C<bug_srcpackage_id_pkg_id>

=over 4

=item * L</bug_id>

=item * L</src_pkg_id>

=back

=cut

__PACKAGE__->add_unique_constraint("bug_srcpackage_id_pkg_id", ["bug_id", "src_pkg_id"]);

=head1 RELATIONS

=head2 bug

Type: belongs_to

Related object: L<Debbugs::DB::Result::Bug>

=cut

__PACKAGE__->belongs_to(
  "bug",
  "Debbugs::DB::Result::Bug",
  { id => "bug_id" },
  { is_deferrable => 1, on_delete => "CASCADE", on_update => "CASCADE" },
);

=head2 src_pkg

Type: belongs_to

Related object: L<Debbugs::DB::Result::SrcPkg>

=cut

__PACKAGE__->belongs_to(
  "src_pkg",
  "Debbugs::DB::Result::SrcPkg",
  { id => "src_pkg_id" },
  { is_deferrable => 1, on_delete => "CASCADE", on_update => "CASCADE" },
);


# Created by DBIx::Class::Schema::Loader v0.07025 @ 2013-01-22 21:35:43
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:k8ZDk5IbnGWbhwRJ17dNXA


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
