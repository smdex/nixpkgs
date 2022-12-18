{ lib
, buildPythonPackage
, callPackage
, fetchPypi
, appdirs
, cryptography
, dogpile-cache
, jmespath
, jsonpatch
, keystoneauth1
, munch
, netifaces
, os-service-types
, pbr
, pythonOlder
, pyyaml
, requestsexceptions
}:

buildPythonPackage rec {
  pname = "openstacksdk";
  version = "0.103.0";
  format = "setuptools";

  disabled = pythonOlder "3.6";

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-T58RiYZgOWdDXzl2s+BZlQpxvY5BqDFsyK+y2WaKB0E=";
  };

  propagatedBuildInputs = [
    appdirs
    cryptography
    dogpile-cache
    jmespath
    jsonpatch
    keystoneauth1
    munch
    netifaces
    os-service-types
    pbr
    requestsexceptions
    pyyaml
  ];

  # Checks moved to 'passthru.tests' to workaround slowness
  doCheck = false;

  passthru.tests = {
    tests = callPackage ./tests.nix { };
  };

  pythonImportsCheck = [
    "openstack"
  ];

  meta = with lib; {
    description = "An SDK for building applications to work with OpenStack";
    homepage = "https://github.com/openstack/openstacksdk";
    license = licenses.asl20;
    maintainers = teams.openstack.members;
  };
}
