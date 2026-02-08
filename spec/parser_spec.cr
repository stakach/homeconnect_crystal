require "./spec_helper"
require "../src/homeconnect_local/parser"

describe HomeconnectLocal::Parser do
  it "parses feature mapping and device description" do
    feature_xml = File.read(File.join(__DIR__, "fixtures", "feature_mapping.xml"))
    device_xml = File.read(File.join(__DIR__, "fixtures", "device_description.xml"))

    dd = HomeconnectLocal::Parser.parse_device_description(device_xml, feature_xml)

    dd.info["brand"].as_s.should eq("Bosch")
    dd.status.size.should eq(1)
    dd.status[0].name.should eq("BSH.Common.Status.OperationState")

    enum_map = dd.status[0].enum_map || raise "expected enum map for operation state"
    enum_map[1].should eq("On")

    dd.option.size.should eq(1)
    dd.option[0].min.should eq(0.0)
    dd.option[0].max.should eq(3600.0)

    dd.program.size.should eq(1)
    dd.program[0].options.should eq([2])
  end

  it "parses XML with default namespaces" do
    feature_xml = <<-XML
    <?xml version="1.0" encoding="utf-8"?>
    <featureMappingFile xmlns="http://example.com/fm">
      <featureDescription>
        <feature refUID="0200">BSH.Common.Command.AbortProgram</feature>
      </featureDescription>
      <enumDescriptionList>
        <enumDescription refENID="0203">
          <enumMember refValue="1">On</enumMember>
        </enumDescription>
      </enumDescriptionList>
    </featureMappingFile>
    XML

    device_xml = <<-XML
    <?xml version="1.0" encoding="utf-8"?>
    <device xmlns="http://example.com/dd">
      <description>
        <brand>Bosch</brand>
      </description>
      <statusList>
        <status uid="0200" enumerationType="0203" refCID="03" />
      </statusList>
    </device>
    XML

    dd = HomeconnectLocal::Parser.parse_device_description(device_xml, feature_xml)
    dd.info["brand"].as_s.should eq("Bosch")
    dd.status.size.should eq(1)
    dd.status[0].name.should eq("BSH.Common.Command.AbortProgram")
    enum_map = dd.status[0].enum_map || raise "expected enum map for namespaced xml"
    enum_map[1].should eq("On")
  end
end
