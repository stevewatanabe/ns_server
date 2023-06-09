# @author Couchbase <info@couchbase.com>
# @copyright 2020-Present Couchbase, Inc.
#
# Use of this software is governed by the Business Source License included in
# the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
# file, in accordance with the Business Source License, use of this software
# will be governed by the Apache License, Version 2.0, included in the file
# licenses/APL2.txt.
import atexit
from abc import ABC, abstractmethod
import requests
import string
import random
import time
import io
from contextlib import redirect_stdout

from traceback_with_variables import print_exc

from testlib.node import Node


def get_appropriate_cluster(cluster, auth, start_index, requirements,
                            tmp_cluster_dir, kill_nodes):
    if cluster is not None:
        # If we can use the existing cluster then we should
        if len(requirements.get_unmet_requirements(cluster)) == 0:
            return cluster

        # Attempt to satisfy the requirements with the existing cluster if
        # possible
        satisfiable, unsatisfied = requirements.is_satisfiable(cluster)
        if satisfiable:
            for requirement in unsatisfied:
                requirement.make_met(cluster)
            return cluster

        # Teardown the old cluster
        cluster.teardown()
        # We no longer need to kill these nodes. A new atexit function will
        # be registered in requirements.create_cluster
        atexit.unregister(kill_nodes)

        start_index = cluster.start_index + len(cluster.processes)

    # Create a new cluster satisfying the requirements
    print(f"Starting cluster to satisfy requirements: {requirements}")
    cluster = requirements.create_cluster(auth, start_index, tmp_cluster_dir,
                                          kill_nodes)
    print("\n======================================="
          "=========================================\n")
    return cluster


def run_testset(testset_class, test_names, cluster, testset_name,
                intercept_output=True):
    errors = []
    not_ran = []
    executed = 0
    print(f"\nStarting testset: {testset_name}...")

    testset_instance = testset_class(cluster)

    _, err = safe_test_function_call(testset_instance, 'setup', [cluster],
                                     intercept_output=intercept_output)

    if err is not None:
        return 0, [err]

    try:
        for test in test_names:
            executed += 1
            _, err = safe_test_function_call(testset_instance, test,
                                             [cluster], verbose=True,
                                             intercept_output=intercept_output)
            if err is not None:
                errors.append(err)

            _, err = safe_test_function_call(testset_instance, 'test_teardown',
                                             [cluster],
                                             intercept_output=intercept_output)
            if err is not None:
                errors.append(err)
                # Don't try to run further tests as test_teardown failure will
                # likely cause additional test failures which are irrelevant
                for not_ran_test in test_names[executed:]:
                    not_ran.append((not_ran_test,
                                    "Earlier test_teardown failed"))
                break
    finally:
        _, err = safe_test_function_call(testset_instance, 'teardown',
                                         [cluster],
                                         intercept_output=intercept_output)
        if err is not None:
            errors.append(err)

    return executed, errors, not_ran


def safe_test_function_call(testset, testfunction, args, verbose=False,
                            intercept_output=True):
    res = None
    error = None
    if hasattr(testset, '__name__'):
        testname = f"{testset.__name__}.{testfunction}"
    else:
        testname = f"{type(testset).__name__}.{testfunction}"
    if verbose: print(f"  {testname}... ", end='', flush=True)
    f = io.StringIO()
    start = time.time()
    try:
        if intercept_output:
            with redirect_stdout(f):
                res = getattr(testset, testfunction)(*args)
        else:
            res = getattr(testset, testfunction)(*args)
        if verbose: print(f"\033[32m passed \033[0m{timedelta_str(start)}")
    except Exception as e:
        if verbose:
            print(f"\033[31m failed ({e}) \033[0m{timedelta_str(start)}")
        else:
            print(f"\033[31m  {testname} failed ({e}) \033[0m")
        print_exc()
        print()
        output = f.getvalue()
        if len(output) > 0:
            extra_cr = '\n' if output[-1] != '\n' else ''
            print(
              f"================== {testfunction}() output begin =================\n"
              f"{output}{extra_cr}"
              f"=================== {testfunction}() output end ==================\n")
        error = (testname, e)
    return res, error


def timedelta_str(start):
    delta_s = time.time() - start
    if delta_s > 10:
        return red(f"[{round(delta_s)}s]")
    if delta_s > 5:
        return red(f"[{delta_s:.1f}s]")
    elif delta_s > 1:
        return f"[{delta_s:.1f}s]"
    elif delta_s > 0.1:
        return f"[{delta_s:.2f}s]"
    else:
        return f""


def red(str):
    return f"\033[31m{str}\033[0m"


class BaseTestSet(ABC):
    def __init__(self, cluster):
        self.cluster = cluster

    @staticmethod
    @abstractmethod
    def requirements():
        """
        Executed before any test in the testset.
        Returns requirements for cluster needed for testset

        """
        raise NotImplementedError()

    @abstractmethod
    def setup(self, cluster):
        """
        Executed before any test in the testset.

        """
        raise NotImplementedError()

    @abstractmethod
    def teardown(self, cluster):
        """
        Executed when all tests are finished.

        """
        raise NotImplementedError()

    def test_teardown(self, cluster):
        """
        Executed when after each test finishes.

        """
        pass


def delete_config_key(cluster, key):
    return post_succ(cluster, '/diag/eval', data=f'ns_config:delete({key})')


def request(method, cluster_or_node, path, expected_code=None, **kwargs):
    kwargs_with_auth = set_default_auth(cluster_or_node, **kwargs)
    if isinstance(cluster_or_node, Node):
        url = cluster_or_node.url + path
    else:
        url = cluster_or_node.connected_nodes[0].url + path
    res = requests.request(method, url, **kwargs_with_auth)
    if expected_code is not None:
        assert_http_code(expected_code, res),
    return res


def put_succ(cluster_or_node, path, expected_code=200, **kwargs):
    return request('PUT', cluster_or_node, path, expected_code, **kwargs)


def post_succ(cluster_or_node, path, expected_code=200, **kwargs):
    return request('POST', cluster_or_node, path, expected_code, **kwargs)


def post_fail(cluster_or_node, path, expected_code, **kwargs):
    return request('POST', cluster_or_node, path, expected_code, **kwargs)


def post(cluster_or_node, path, **kwargs):
    return request('POST', cluster_or_node, path, None, **kwargs)


def get_succ(cluster_or_node, path, expected_code=200, **kwargs):
    return request('GET', cluster_or_node, path, expected_code, **kwargs)


def get_fail(cluster_or_node, path, expected_code, **kwargs):
    return request('GET', cluster_or_node, path, expected_code, **kwargs)


def get(cluster_or_node, path, **kwargs):
    return request('GET', cluster_or_node, path, None, **kwargs)


def ensure_deleted(cluster, path, **kwargs):
    res = delete(cluster, path, **kwargs)
    code = res.status_code
    assert code == 200 or code == 404, format_http_error(res, [200, 404])
    return res


def delete(cluster_or_node, path, **kwargs):
    return request('DELETE', cluster_or_node, path, None, **kwargs)


def delete_succ(cluster_or_node, path, **kwargs):
    return request('DELETE', cluster_or_node, path, 200, **kwargs)


def set_default_auth(cluster_or_node, **kwargs):
    if 'auth' not in kwargs:
        new_kwargs = kwargs.copy()
        new_kwargs.update({'auth': cluster_or_node.auth})
        return new_kwargs
    return kwargs


def assert_http_code(expected_code, res):
    code = res.status_code
    assert code == expected_code, format_http_error(res, [expected_code])


def format_http_error(res, expected_codes):
    expected_codes_str = " or ".join([str(c) for c in expected_codes])
    return f"{res.request.method} {res.url} " \
           f"returned {res.status_code} {res.reason} " \
           f"(expected {expected_codes_str})" \
           f", response body: {res.text}"


def assert_json_key(expected_key, json, context):
    assert expected_key in json.keys(), \
        f"({context}) '{expected_key}' missing in json: {json}"
    return json[expected_key]


def random_str(n):
    return ''.join(random.choices(string.ascii_lowercase +
                                  string.digits, k=n))


def json_response(response, error):
    try:
        return response.json()
    except requests.exceptions.JSONDecodeError:
        assert False, error


def delete_all_buckets(cluster, **kwargs):
    buckets = get_succ(cluster, "/pools/default/buckets", **kwargs)
    for bucket in buckets.json():
        cluster.delete_bucket(bucket['name'])


def get_otp_nodes(cluster):
    info = json_response(get(cluster, "/nodeStatuses"),
                         "/nodeStatuses response was not json")
    return {k: info[k]['otpNode'] for k in info}
