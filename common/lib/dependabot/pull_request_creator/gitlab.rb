# frozen_string_literal: true

require "dependabot/clients/gitlab_with_retries"
require "dependabot/pull_request_creator"
require "gitlab"

module Dependabot
  class PullRequestCreator
    class Gitlab
      attr_reader :source, :branch_name, :base_commit, :credentials,
                  :files, :pr_description, :pr_name, :commit_message,
                  :author_details, :labeler, :approvers, :assignee,
                  :milestone

      def initialize(source:, branch_name:, base_commit:, credentials:,
                     files:, commit_message:, pr_description:, pr_name:,
                     author_details:, labeler:, approvers:, assignee:,
                     milestone:)
        @source         = source
        @branch_name    = branch_name
        @base_commit    = base_commit
        @credentials    = credentials
        @files          = files
        @commit_message = commit_message
        @pr_description = pr_description
        @pr_name        = pr_name
        @author_details = author_details
        @labeler        = labeler
        @approvers      = approvers
        @assignee       = assignee
        @milestone      = milestone
      end

      def create
        return if branch_exists? && merge_request_exists?

        if branch_exists?
          create_commit unless commit_exists?
        else
          create_branch
          create_commit
        end

        labeler.create_default_labels_if_required
        merge_request = create_merge_request
        return unless merge_request

        annotate_merge_request(merge_request)

        merge_request
      end

      private

      def gitlab_client_for_source
        @gitlab_client_for_source ||=
          Dependabot::Clients::GitlabWithRetries.for_source(
            source: source,
            credentials: credentials
          )
      end

      def branch_exists?
        @branch_ref ||=
          gitlab_client_for_source.branch(source.repo, branch_name)
        true
      rescue ::Gitlab::Error::NotFound
        false
      end

      def commit_exists?
        @commits ||=
          gitlab_client_for_source.commits(source.repo, ref_name: branch_name)
        @commits.first.message == commit_message
      end

      def merge_request_exists?
        gitlab_client_for_source.merge_requests(
          source.repo,
          source_branch: branch_name,
          target_branch: source.branch || default_branch,
          state: "all"
        ).any?
      end

      def create_branch
        gitlab_client_for_source.create_branch(
          source.repo,
          branch_name,
          base_commit
        )
      end

      def create_commit
        if files.count == 1 && files.first.type == "submodule"
          return create_submodule_update_commit
        end

        actions = files.map do |file|
          if file.type == "symlink"
            {
              action: "update",
              file_path: file.symlink_target,
              content: file.content
            }
          else
            {
              action: "update",
              file_path: file.path,
              content: file.content
            }
          end
        end

        gitlab_client_for_source.create_commit(
          source.repo,
          branch_name,
          commit_message,
          actions
        )
      end

      def create_submodule_update_commit
        file = files.first

        gitlab_client_for_source.edit_submodule(
          source.repo,
          file.path.gsub(%r{^/}, ""),
          branch: branch_name,
          commit_sha: file.content,
          commit_message: commit_message
        )
      end

      def create_merge_request
        gitlab_client_for_source.create_merge_request(
          source.repo,
          pr_name,
          source_branch: branch_name,
          target_branch: source.branch || default_branch,
          description: pr_description,
          remove_source_branch: true,
          assignee_id: assignee,
          labels: labeler.labels_for_pr.join(","),
          milestone_id: milestone
        )
      end

      def annotate_merge_request(merge_request)
        add_approvers_to_merge_request(merge_request) if approvers&.any?
      end

      def add_approvers_to_merge_request(merge_request)
        approvers_hash =
          Hash[approvers.keys.map { |k| [k.to_sym, approvers[k]] }]

        gitlab_client_for_source.edit_merge_request_approvers(
          source.repo,
          merge_request.iid,
          approver_ids: approvers_hash[:approvers],
          approver_group_ids: approvers_hash[:group_approvers]
        )
      end

      def default_branch
        @default_branch ||=
          gitlab_client_for_source.project(source.repo).default_branch
      end
    end
  end
end
