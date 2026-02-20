

# https://docs.aws.amazon.com/cli/latest/reference/network-firewall/create-rule-group.html
# https://www.iana.org/assignments/protocol-numbers/protocol-numbers.xhtml
AWS network-firewall create-rule-group \
--rule-group-name allow-sqlserver-rule-group-0-0-0-0-0 \
--type STATELESS \
--capacity 100 \
--rule-group '
{
"RulesSource": {
    "StatelessRulesAndCustomActions": {
        "StatelessRules": [{
            "Priority": 100,
            "RuleDefinition": {
                "Actions": ["aws:pass"],
                "MatchAttributes": {
                    "Sources": [{"AddressDefinition": "0.0.0.0/0"}],
                    "Destinations": [{"AddressDefinition": "'$DB_HOST_IP'/32"}],
                    "DestinationPorts": [{"FromPort": '$DB_PORT',"ToPort": '$DB_PORT'}],
                    "Protocols": [6]
                }
            }
        }],
        "CustomActions": []
    }
}
}' \
--description "Allow sqlserver from 0.0.0.0/0" \
--profile databricks-power-user-997819012307 \
--region us-west-2 \
--no-paginate --no-cli-pager

read -rd "\n" FW_RULE_ARN <<< "$(jq -r '.RuleGroupResponse.RuleGroupArn' /tmp/aws_stdout.$$)"
export FW_RULE_ARN

AWS network-firewall create-firewall-policy \
    --firewall-policy-name allow-sqlserver-policy \
    --firewall-policy '
{
"StatelessRuleGroupReferences": [{
    "ResourceArn": "'$FW_RULE_ARN'", 
    "Priority":100}],
"StatelessDefaultActions": ["aws:drop"],
"StatelessFragmentDefaultActions":  ["aws:drop"]
}
' \
--description "Allow sqlserver from 0.0.0.0/0" \
--profile databricks-power-user-997819012307 \
--region us-west-2 \
--no-paginate --no-cli-pager

read -rd "\n" FW_POLICY_ARN <<< "$(jq -r '.FirewallPolicyResponse.FirewallPolicyArn' /tmp/aws_stdout.$$)"
export FW_POLICY_ARN

AWS network-firewall create-firewall \
--firewall-name allow-sqlserver-firewall \
--firewall-policy-arn "'$FW_POLICY_ARN'" \
--vpc-id "$DB_VPC_ID" \
--subnet-mappings '
[
{"SubnetId": "subnet-15b1a771"},
{"SubnetId": "subnet-1e620346"},
{"SubnetId": "subnet-05715a73"}
]
' \
--description "Allow sqlserver from 0.0.0.0/0" \
--profile databricks-power-user-997819012307 \
--region us-west-2 \
--no-paginate


AWS network-firewall describe-firewall --firewall-name allow-sqlserver-firewall \
--profile databricks-power-user-997819012307 \
--region us-west-2 \
--no-paginate --no-cli-pager


AWS network-firewall delete-firewall \
--firewall-name allow-sqlserver-firewall \
--profile databricks-power-user-997819012307 \
--region us-west-2 \
--no-paginate --no-cli-pager

AWS network-firewall delete-firewall-policy \
--firewall-policy-name allow-sqlserver-policy \
--profile databricks-power-user-997819012307 \
--region us-west-2 \
--no-paginate --no-cli-pager

AWS network-firewall delete-rule-group \
--rule-group-name allow-sqlserver-rule-group-0-0-0-0-0 \
--type STATELESS \
--profile databricks-power-user-997819012307 \
--region us-west-2 \
--no-paginate --no-cli-pager