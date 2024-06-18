""" Main module for handling incoming GitHub webhook event"""
import re
from .lib import WebHookEvent, config, GithubApi


def handle_request(request, configuration=None):
    """Responds to any HTTP request.
    Args:
        request (flask.Request): HTTP request object.
    Returns:
        The response text or any set of values that can be turned into a
        Response object using
        `make_response <http://flask.pocoo.org/docs/1.0/api/#flask.Flask.make_response>`.
    """
    event = WebHookEvent(request)
    if configuration is None:
        print("loading configuration")
        configuration = config.load('config.json')

    print("verifying signature")
    event.verify_signature(configuration)

    print(f"DEBUG: is comment event {event.is_comment_event()}")
    print(f"DEBUG: is push event {event.is_push_event()}")
    print(f"DEBUG: incoming branch {event.info().incoming_branch}")

    if event.is_push_event():
        print("Push event detected. It might be a push from merge branch")
        if configuration.github.merge_branch_prefix in event.info().incoming_branch:
            handle_incoming_push(event.info().incoming_branch, configuration)
        else:
            print("incoming branch is not a merge branch")
    elif event.is_comment_event() and event.info().comment_body.strip() == "!help-merge-me":
        print("!help-merge-me command event detected")
        handle_incoming_comment(event.info(), configuration)
    else:
        print(f"not applicable event")


def porting_branch(configuration, incoming_branch, stable_branch):
    return f"{configuration.github.merge_branch_prefix}_{incoming_branch}_to_{stable_branch}"


def handle_incoming_comment(payload_info, configuration):
    """
      Main logic for handling incoming GitHub webhook event
    """
    pr_id = payload_info.issue_number
    pr_name = payload_info.issue_title
    print(f"handling incoming comment event on {pr_name}")

    github_api = GithubApi(configuration.github)

    pull = github_api.repository().get_pull_by_id(pr_id)
    if pull.is_merged():
        print("PR already merged. exiting")
        return

    branches = list(configuration.github.all_branches())
    incoming_branch = pull.head.ref
    target_branch = pull.base.ref

    if target_branch in branches:
        branches.remove(target_branch)

    porting_branches = []

    for stable_branch in branches:
        if github_api.has_merge_conflict(stable_branch,incoming_branch):
            print(f"branches {incoming_branch} and {stable_branch} have a merge conflict! creating porting branch to address "
                  f"those changes...")

            new_branch = f"{configuration.github.merge_branch_prefix}_{incoming_branch}_to_{stable_branch}"
            print(f"creating porting branch: '{new_branch}' from '{stable_branch}'")
            github_api.create_new_branch(new_branch,stable_branch)
            print(f"new porting branch: '{new_branch}' created.")
            porting_branches.append((new_branch,stable_branch,incoming_branch))

    if any(porting_branches):
        pull.create_issue_comment(github_api.comment_conflict(porting_branches,
                                                              f"Hello, @{pull.user.login} {len(porting_branches)} new  created to help "
                                                              f"you port this change to {target_branch}. Please follow steps to resolve conflict for each mainline branch. PRs will be created automatically after you push merge to porting branches"))


def handle_incoming_push(merge_branch, configuration):
    """
      Main logic for handling incoming GitHub webhook event
    """
    print(f"creating PR for {merge_branch}")

    github_api = GithubApi(configuration.github)

    pattern = re.compile(f"{configuration.github.merge_branch_prefix}_(?P<head>.*)_to_(?P<base>.*)")
    match = pattern.match(merge_branch)
    original_branch = match.group("head")
    stable_branch = match.group("base")

    print(f"DEBUG: {original_branch} {stable_branch}")

    if github_api.repository().any_pulls(merge_branch, stable_branch):
        print("PR already exists. exiting")
        return

    original_pull = github_api.repository().get_pull_from(original_branch)

    if original_pull is None:
        print("Cannot find original conflicting pull request")
        return

    new_pr = github_api.create_pull_request(
        draft=configuration.pr.draft,
        assignees=list(map(lambda x: x.login, original_pull.assignees)),
        labels=["merge"],
        title=f"[Merge Conflict Fix] port '{original_pull.title}' to {stable_branch}",
        body_prefix=f"This is autogenerated Pull Request for porting #{original_pull.number} to {stable_branch}",
        base=stable_branch,
        head=merge_branch
    )

    new_pr.create_issue_comment("!ci-build-me")
    print(f"new PR: '{new_pr.title}' created. Please resolve it before merge...")
    original_pull.create_issue_comment(
        f"Porting branch #{new_pr.number} to resolve conflict with {stable_branch} created. Please merge it in order to solve conflict between head of this PR and {stable_branch}")
