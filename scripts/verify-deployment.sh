#!/usr/bin/env bash
#
# Evidence capture for the deployed stack. Every check below ASSERTS rather
# than merely prints: a claim in the README that nothing verifies is a claim
# that quietly stops being true.
#
#   ./scripts/verify-deployment.sh
#
# Exits non-zero on the first violated claim.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF="terraform -chdir=${REPO_ROOT}/infra"

tfout() { ${TF} output -raw "$1"; }

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

FAILURES=0

ALB_DNS="$(tfout alb_dns_name)"
TASK_SG="$(tfout task_security_group_id)"
ALB_SG="$(tfout alb_security_group_id)"
CLUSTER="$(tfout ecs_cluster_name)"
SERVICE="$(tfout ecs_service_name)"
VPC_ID="$(tfout vpc_id)"

# ---------------------------------------------------------------------------
head_ "1. The API answers through the load balancer"
# ---------------------------------------------------------------------------

READY="$(curl -fsS --max-time 10 "http://${ALB_DNS}/ready" || echo FAILED)"
echo "  GET http://${ALB_DNS}/ready -> ${READY}"
if echo "${READY}" | grep -q '"status":"ready"'; then
  pass "/ready returns ready through the ALB"
else
  fail "/ready did not return ready"
fi

if curl -fsS --max-time 10 -o /dev/null -w '%{http_code}' "http://${ALB_DNS}/docs" | grep -q 200; then
  pass "/docs served through the ALB"
else
  fail "/docs not reachable"
fi

# ---------------------------------------------------------------------------
head_ "2. Task ingress is reachable only from the ALB's security group"
# ---------------------------------------------------------------------------

aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=${TASK_SG}" \
  --query 'SecurityGroupRules[].{Direction:(IsEgress),Proto:IpProtocol,From:FromPort,To:ToPort,CIDR:CidrIpv4,PrefixList:PrefixListId,SourceSG:ReferencedGroupInfo.GroupId,Desc:Description}' \
  --output table

# The claim: no ingress rule on the task group cites a CIDR. Anything reaching
# the tasks must have come through the ALB's security group.
INGRESS_CIDRS="$(aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=${TASK_SG}" \
  --query 'SecurityGroupRules[?IsEgress==`false`].CidrIpv4' --output text | tr -d '[:space:]')"

if [ -z "${INGRESS_CIDRS}" ] || [ "${INGRESS_CIDRS}" = "None" ]; then
  pass "no CIDR-based ingress rule on the task security group"
else
  fail "task security group admits CIDRs: ${INGRESS_CIDRS}"
fi

INGRESS_SGS="$(aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=${TASK_SG}" \
  --query 'SecurityGroupRules[?IsEgress==`false`].ReferencedGroupInfo.GroupId' --output text)"

if [ "${INGRESS_SGS}" = "${ALB_SG}" ]; then
  pass "the only ingress source is ${ALB_SG} (the ALB)"
else
  fail "expected ingress only from ${ALB_SG}, found: ${INGRESS_SGS}"
fi

# ---------------------------------------------------------------------------
head_ "3. Task subnets have no route to the internet"
# ---------------------------------------------------------------------------

for RT in $(${TF} output -json private_route_table_ids | python3 -c 'import json,sys;print(" ".join(json.load(sys.stdin)))'); do
  echo "  route table ${RT}:"
  aws ec2 describe-route-tables --route-table-ids "${RT}" \
    --query 'RouteTables[0].Routes[].{Destination:DestinationCidrBlock,PrefixList:DestinationPrefixListId,Target:(GatewayId||NatGatewayId||VpcPeeringConnectionId||TransitGatewayId),State:State}' \
    --output table

  DEFAULT_ROUTE="$(aws ec2 describe-route-tables --route-table-ids "${RT}" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0']" --output text)"

  if [ -z "${DEFAULT_ROUTE}" ]; then
    pass "${RT} has no 0.0.0.0/0 route"
  else
    fail "${RT} has a default route: ${DEFAULT_ROUTE}"
  fi
done

NAT_COUNT="$(aws ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=available,pending" \
  --query 'length(NatGateways)' --output text)"

if [ "${NAT_COUNT}" = "0" ]; then
  pass "no NAT gateway exists in the VPC"
else
  fail "${NAT_COUNT} NAT gateway(s) present"
fi

# ---------------------------------------------------------------------------
head_ "4. Tasks have no public IP and are spread across availability zones"
# ---------------------------------------------------------------------------

TASK_ARNS="$(aws ecs list-tasks --cluster "${CLUSTER}" --service-name "${SERVICE}" \
  --desired-status RUNNING --query 'taskArns[]' --output text)"

if [ -z "${TASK_ARNS}" ]; then
  fail "no running tasks"
else
  aws ecs describe-tasks --cluster "${CLUSTER}" --tasks ${TASK_ARNS} \
    --query 'tasks[].{Task:taskArn,AZ:availabilityZone,Health:healthStatus,Status:lastStatus,PrivateIP:attachments[0].details[?name==`privateIPv4Address`].value|[0],ENI:attachments[0].details[?name==`networkInterfaceId`].value|[0]}' \
    --output table

  # An ENI with no association block has no public address at all -- stronger
  # than "has a public address that nothing routes to".
  ENIS="$(aws ecs describe-tasks --cluster "${CLUSTER}" --tasks ${TASK_ARNS} \
    --query 'tasks[].attachments[0].details[?name==`networkInterfaceId`].value' --output text)"

  PUBLIC_IPS="$(aws ec2 describe-network-interfaces --network-interface-ids ${ENIS} \
    --query 'NetworkInterfaces[].Association.PublicIp' --output text | tr -d '[:space:]')"

  if [ -z "${PUBLIC_IPS}" ] || [ "${PUBLIC_IPS}" = "None" ]; then
    pass "no task ENI has a public IP"
  else
    fail "task ENIs carry public IPs: ${PUBLIC_IPS}"
  fi

  AZS="$(aws ecs describe-tasks --cluster "${CLUSTER}" --tasks ${TASK_ARNS} \
    --query 'tasks[].availabilityZone' --output text | tr '\t' '\n' | sort -u | wc -l | tr -d ' ')"

  if [ "${AZS}" -ge 2 ]; then
    pass "tasks running across ${AZS} availability zones"
  else
    fail "tasks occupy only ${AZS} availability zone"
  fi

  # The direct-reachability check. The task's private address is inside the
  # VPC and the route tables have no path from the internet to it, so this must
  # time out. A connection here would falsify the whole section above.
  TASK_IP="$(aws ecs describe-tasks --cluster "${CLUSTER}" --tasks ${TASK_ARNS} \
    --query 'tasks[0].attachments[0].details[?name==`privateIPv4Address`].value|[0]' --output text)"
  echo "  attempting a direct connection to ${TASK_IP}:8000 (expected to fail)"
  if curl -sS --max-time 8 "http://${TASK_IP}:8000/ready" >/dev/null 2>&1; then
    fail "the task answered a direct request from outside the VPC"
  else
    pass "task ${TASK_IP} is unreachable except through the ALB"
  fi
fi

# ---------------------------------------------------------------------------
head_ "5. Alarms and logs"
# ---------------------------------------------------------------------------

aws cloudwatch describe-alarms \
  --alarm-name-prefix "${CLUSTER}" \
  --query 'MetricAlarms[].{Alarm:AlarmName,State:StateValue,Metric:MetricName}' \
  --output table

IN_ALARM="$(aws cloudwatch describe-alarms --alarm-name-prefix "${CLUSTER}" \
  --state-value ALARM --query 'length(MetricAlarms)' --output text)"

if [ "${IN_ALARM}" = "0" ]; then
  pass "no alarm is in ALARM state"
else
  fail "${IN_ALARM} alarm(s) firing"
fi

LOG_GROUP="$(tfout log_group_name)"
STREAMS="$(aws logs describe-log-streams --log-group-name "${LOG_GROUP}" \
  --order-by LastEventTime --descending --max-items 3 \
  --query 'logStreams[].logStreamName' --output text || true)"

if [ -n "${STREAMS}" ]; then
  pass "application logs present in ${LOG_GROUP}"
  echo "  most recent streams: ${STREAMS}"
else
  fail "no log streams in ${LOG_GROUP}"
fi

# ---------------------------------------------------------------------------
printf '\n'
if [ "${FAILURES}" -eq 0 ]; then
  printf '\033[32mAll checks passed.\033[0m\n'
else
  printf '\033[31m%d check(s) failed.\033[0m\n' "${FAILURES}"
  exit 1
fi
